const fs = require("node:fs");
const path = require("node:path");

const marker = "<!-- aviation-ingestion-alert -->";

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

/** Maintain one failure issue and resolve it after successful release validation. */
async function notify({ github, context, core }, environment = process.env) {
  let published = [];
  try {
    const response = JSON.parse(
      fs.readFileSync("published-status.json", "utf8"),
    );
    published = response.result.structuredContent.results.flatMap((source) =>
      [source.version, source.nextVersion].filter(Boolean),
    );
  } catch {
    core.warning("Published source status could not be verified.");
  }
  const releases = summarizeReleases(
    readArrays("checked"),
    readArrays("reports"),
    Date.now(),
    published,
  );
  const failed =
    environment.CHECK_RESULT !== "success" ||
    environment.INGEST_RESULT !== "success" ||
    releases.length === 0 ||
    releases.some((release) => release.status !== "success");
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
  if (!failed) {
    if (existing)
      await github.rest.issues.update({
        ...repository,
        issue_number: existing.number,
        state: "closed",
        state_reason: "completed",
      });
    core.info("Every discovered release passed validation and ingestion.");
    return;
  }

  const run = `${context.serverUrl}/${repository.owner}/${repository.repo}/actions/runs/${context.runId}`;
  const rows = releases.map(
    (release) =>
      `| ${release.source} | ${release.cycle} | ${release.upcoming ? "Upcoming" : "Current/latest"} | ${release.effectiveFrom} | ${release.status} | ${release.parseErrors} |`,
  );
  const failures = releases
    .filter((release) => release.status !== "success")
    .map((release) => `${release.source}/${release.cycle}`)
    .sort();
  const fingerprint = `<!-- failed-releases:${JSON.stringify(failures)} -->`;
  const body = [
    marker,
    "@RISCfuture A source release has parsing gaps, failed ingestion, or could not be checked.",
    "Upcoming releases must parse and publish before their effective date. Expired data will become unavailable.",
    `[Inspect the workflow run](${run}) · [Fly ingestion logs](https://fly.io/apps/aviation-mcp-ingest/monitoring)`,
    `Source discovery: **${environment.CHECK_RESULT}**. Ingestion: **${environment.INGEST_RESULT}**.`,
    [
      "| Source | Cycle | Timing | Effective from (UTC) | Result | Parse errors |",
      "| --- | --- | --- | --- | --- | --- |",
      ...rows,
    ].join("\n"),
    "Valid records are published when recoverable errors occur; the affected source remains partial. Inspect get_data_status for parser diagnostics. A missing or pending result is not a successful parse.",
    "This issue updates on each failed scheduled check and closes after all discovered releases succeed.",
    fingerprint,
  ].join("\n\n");
  const title =
    "Aviation data gaps or ingestion failures — check upcoming cycles";
  if (existing) {
    const previous = JSON.parse(
      existing.body.match(/<!-- failed-releases:(.*?) -->/)?.[1] ?? "[]",
    );
    const newlyFailed = failures.filter(
      (failure) => !previous.includes(failure),
    );
    if (newlyFailed.length)
      await github.rest.issues.createComment({
        ...repository,
        issue_number: existing.number,
        body: `@RISCfuture Additional releases need attention: ${newlyFailed.join(", ")}. [Failed run](${run}).`,
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
  core.warning(`Source validation needs attention: ${run}`);
}

module.exports = { summarizeReleases, notify };
