const fs = require("node:fs");
const path = require("node:path");

const marker = "<!-- aviation-ingestion-alert -->";
const HOUR = 3_600_000;
/** How long before a published version expires its successor must be staged. */
const SUCCESSOR_LEAD = {
  nasr: 7 * 24 * HOUR,
  cifp: 7 * 24 * HOUR,
  dof: 24 * HOUR,
};
/** Release results that need the owner's attention, rather than informational gaps. */
const FAILED_RELEASE_STATUSES = new Set([
  "failure",
  "withheld: incomplete release",
  "publication not confirmed",
  "not validated",
  "pending",
]);
/** Job results that do not indicate a failure for jobs that may legitimately be skipped. */
const OPTIONAL_JOB_RESULTS = new Set(["success", "skipped"]);

/** Summarize every discovered release, including releases without a completed import. */
function summarizeReleases(releases, reports, now, published = []) {
  return releases.map((release) => {
    const report = reports.find((entry) =>
      entry.downloads.some(
        (download) =>
          download.source === release.source &&
          download.cycle === release.cycle &&
          download.effectiveFrom === release.effectiveFrom,
      ),
    );
    const version = published.find(
      (candidate) =>
        candidate.source === release.source &&
        (candidate.cycle === release.cycle ||
          candidate.validation?.download?.cycle === release.cycle) &&
        Date.parse(candidate.effectiveFrom) ===
          Date.parse(release.effectiveFrom),
    );
    const parseErrors = version?.validation?.parse_errors?.count ?? 0;
    let status = report?.status ?? "not validated";
    if (status === "withheld") status = "withheld: incomplete release";
    if (status === "success") {
      if (!version) status = "publication not confirmed";
      else if (parseErrors > 0) status = "published with gaps";
    }
    return {
      source: release.source,
      cycle: release.cycle,
      effectiveFrom: release.effectiveFrom,
      upcoming: Date.parse(release.effectiveFrom) > now,
      status,
      parseErrors,
    };
  });
}

/** Find sources that are unavailable, or that expire soon with no successor staged. */
function coverageProblems(statuses, now) {
  return statuses.flatMap((status) => {
    if (status.status === "unavailable")
      return [
        {
          key: `${status.source}/coverage`,
          status: "unavailable",
          detail: status.reason ?? "No effective validated data is published.",
        },
      ];
    const until = Date.parse(status.version?.effectiveUntil);
    const lead = SUCCESSOR_LEAD[status.source];
    if (
      !lead ||
      Number.isNaN(until) ||
      status.nextVersion ||
      until - now > lead
    )
      return [];
    return [
      {
        key: `${status.source}/coverage`,
        status: "expiring without successor",
        detail: `Release ${status.version.cycle} expires at ${status.version.effectiveUntil} and no replacement is staged; the source becomes unavailable then.`,
      },
    ];
  });
}

/** Find workflow jobs that failed. */
function jobProblems(environment) {
  const results = {
    check: [environment.CHECK_RESULT, false],
    ingest: [environment.INGEST_RESULT, false],
    terrain: [environment.TERRAIN_RESULT, true],
    purge: [environment.PURGE_RESULT, true],
  };
  return Object.entries(results)
    .filter(([, [result, optional]]) =>
      optional
        ? !OPTIONAL_JOB_RESULTS.has(result ?? "skipped")
        : result !== "success",
    )
    .map(([job, [result]]) => ({
      key: `job/${job}`,
      status: result ?? "missing",
      detail: `The ${job} job did not succeed.`,
    }));
}

/** List everything that needs the owner's attention; parsing gaps alone are informational. */
function problems({ releases, statuses, environment, now }) {
  const releaseProblems = releases
    .filter((release) => FAILED_RELEASE_STATUSES.has(release.status))
    .map((release) => ({
      key: `${release.source}/${release.cycle}`,
      status: release.status,
      detail: `${release.upcoming ? "Upcoming" : "Current"} release effective ${release.effectiveFrom}.`,
    }));
  const discovery = releases.length
    ? []
    : [
        {
          key: "releases",
          status: "none discovered",
          detail: "No source releases were discovered.",
        },
      ];
  const coverage = statuses
    ? coverageProblems(statuses, now)
    : [
        {
          key: "coverage",
          status: "unverified",
          detail: "Published source status could not be read.",
        },
      ];
  return [
    ...jobProblems(environment),
    ...discovery,
    ...releaseProblems,
    ...coverage,
  ];
}

/** Read the JSON arrays produced by source discovery and ingestion jobs. */
function readArrays(directory) {
  if (!fs.existsSync(directory)) return [];
  return fs
    .readdirSync(directory)
    .filter((name) => name.endsWith(".json"))
    .flatMap((name) =>
      JSON.parse(fs.readFileSync(path.join(directory, name), "utf8")),
    );
}

/** Read the per-source results of get_data_status, or undefined when they are unavailable. */
function readStatuses(core) {
  try {
    return JSON.parse(fs.readFileSync("published-status.json", "utf8")).result
      .structuredContent.results;
  } catch {
    core.warning("Published source status could not be verified.");
    return undefined;
  }
}

function issueBody({ problems: found, releases, run, environment }) {
  const problemRows = found.map(
    (problem) => `| ${problem.key} | ${problem.status} | ${problem.detail} |`,
  );
  const releaseRows = releases.map(
    (release) =>
      `| ${release.source} | ${release.cycle} | ${release.upcoming ? "Upcoming" : "Current/latest"} | ${release.effectiveFrom} | ${release.status} | ${release.parseErrors} |`,
  );
  const fingerprint = found
    .map((problem) => `${problem.key}:${problem.status}`)
    .sort();
  return [
    marker,
    "@RISCfuture Aviation data needs attention: an ingestion step failed, a release was withheld, or a source is unavailable or about to expire without a replacement.",
    "The service never serves expired data. A source without an effective release is reported as unavailable until its replacement is published.",
    `[Inspect the workflow run](${run}) · [Fly ingestion logs](https://fly.io/apps/aviation-mcp-ingest/monitoring)`,
    `Source discovery: **${environment.CHECK_RESULT}**. Ingestion: **${environment.INGEST_RESULT}**. Terrain: **${environment.TERRAIN_RESULT}**. Purge: **${environment.PURGE_RESULT}**.`,
    [
      "| Problem | Status | Detail |",
      "| --- | --- | --- |",
      ...problemRows,
    ].join("\n"),
    [
      "| Source | Cycle | Timing | Effective from (UTC) | Result | Parse errors |",
      "| --- | --- | --- | --- | --- | --- |",
      ...releaseRows,
    ].join("\n"),
    "A withheld release was incomplete compared with the published release (a failed record family or a large drop in records) and was not published; the published release keeps serving only until it expires. Parsing gaps in published releases are informational and do not keep this issue open; inspect get_data_status for parser diagnostics.",
    "This issue updates on each run, notifies when a new problem appears or an existing one changes, and closes when no problems remain.",
    `<!-- problems:${JSON.stringify(fingerprint)} -->`,
  ].join("\n\n");
}

/** Maintain one problem issue, notify when problems appear or change, and close it after recovery. */
async function notify(
  { github, context, core },
  environment = process.env,
  now = Date.now(),
) {
  const statuses = readStatuses(core);
  const published = (statuses ?? []).flatMap((source) =>
    [source.version, source.nextVersion].filter(Boolean),
  );
  const releases = summarizeReleases(
    readArrays("checked"),
    readArrays("reports"),
    now,
    published,
  );
  const found = problems({ releases, statuses, environment, now });
  const repository = context.repo;
  const issues = await github.paginate(github.rest.issues.listForRepo, {
    ...repository,
    state: "open",
    creator: "github-actions[bot]",
    per_page: 100,
  });
  const existing = issues.find(
    (issue) => !issue.pull_request && issue.body?.includes(marker),
  );
  if (!found.length) {
    if (existing)
      await github.rest.issues.update({
        ...repository,
        issue_number: existing.number,
        state: "closed",
        state_reason: "completed",
      });
    core.info(
      "Every discovered release is published and every source is covered.",
    );
    return;
  }

  const run = `${context.serverUrl}/${repository.owner}/${repository.repo}/actions/runs/${context.runId}`;
  const body = issueBody({ problems: found, releases, run, environment });
  const title = "Aviation data unavailable, withheld, or failing to ingest";
  if (existing) {
    const previous = JSON.parse(
      existing.body.match(/<!-- problems:(.*?) -->/)?.[1] ?? "[]",
    );
    const changed = found.filter(
      (problem) => !previous.includes(`${problem.key}:${problem.status}`),
    );
    if (changed.length)
      await github.rest.issues.createComment({
        ...repository,
        issue_number: existing.number,
        body: `@RISCfuture New or changed problems: ${changed.map((problem) => `${problem.key} (${problem.status})`).join(", ")}. [Run](${run}).`,
      });
    await github.rest.issues.update({
      ...repository,
      issue_number: existing.number,
      title,
      body,
    });
  } else {
    await github.rest.issues.create({
      ...repository,
      title,
      body,
      assignees: ["RISCfuture"],
    });
  }
  core.warning(`Aviation data needs attention: ${run}`);
}

module.exports = { summarizeReleases, coverageProblems, jobProblems, notify };
