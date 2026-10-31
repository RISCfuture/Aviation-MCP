const assert = require("node:assert/strict");
const {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  rmSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const { summarizeReleases, notify } = require("./ingestion-alerts.cjs");

const current = {
  source: "nasr",
  cycle: "2026-10-01",
  effectiveFrom: "2026-10-01T09:01:00Z",
  effectiveUntil: "2026-10-29T09:01:00Z",
};
const next = {
  source: "nasr",
  cycle: "2026-10-29",
  effectiveFrom: "2026-10-29T09:01:00Z",
  effectiveUntil: "2026-11-26T09:01:00Z",
};

test("identifies upcoming releases that failed or were never attempted", () => {
  const dof = {
    source: "dof",
    cycle: "2026-09-29",
    effectiveFrom: "2026-09-29T00:00:00Z",
  };
  const summaries = summarizeReleases(
    [current, next, dof],
    [
      { downloads: [current], status: "failure" },
      { downloads: [dof], status: "success" },
    ],
    Date.parse("2026-10-28T12:00:00Z"),
    [{ ...dof, cycle: "20260927", validation: { download: dof } }],
  );
  assert.deepEqual(
    summaries.map(({ upcoming, status }) => ({ upcoming, status })),
    [
      { upcoming: false, status: "failure" },
      { upcoming: true, status: "not validated" },
      { upcoming: false, status: "success" },
    ],
  );
});

test("attempts each navigation release independently and reports withheld releases", (t) => {
  const directory = mkdtempSync(path.join(tmpdir(), "aviation-ingest-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  mkdirSync(path.join(directory, "checked"));
  mkdirSync(path.join(directory, "scripts"));
  for (const source of ["nasr", "cifp"])
    writeFileSync(
      path.join(directory, "checked", `${source}.json`),
      JSON.stringify(
        [current, next].map((release) => ({ ...release, source })),
      ),
    );
  writeFileSync(
    path.join(directory, "scripts/run-ingestion-job.sh"),
    [
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      `plan=$(jq -rn --arg encoded "$2" '$encoded | @base64d')`,
      `release=$(jq -r '.[0] | "\\(.source)/\\(.cycle)"' <<< "$plan")`,
      "[[ $release == nasr/2026-10-01 ]] && exit 3",
      "[[ $release != cifp/2026-10-01 ]]",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  const result = spawnSync(
    "bash",
    [
      path.resolve("scripts/ingest-checked-sources.sh"),
      "navigation",
      "checked",
      "reports/navigation.json",
    ],
    { cwd: directory, encoding: "utf8" },
  );
  assert.equal(result.status, 1, result.stderr);
  const reports = JSON.parse(
    readFileSync(path.join(directory, "reports/navigation.json"), "utf8"),
  );
  assert.deepEqual(
    reports.map((report) => [report.downloads[0].source, report.status]),
    [
      ["nasr", "withheld"],
      ["nasr", "success"],
      ["cifp", "failure"],
      ["cifp", "success"],
    ],
  );
  assert.ok(reports.every((report) => report.downloads.length === 1));
});

test("alerts on failures and expiry, notifies on changes, and ignores parsing gaps", async (t) => {
  const directory = mkdtempSync(path.join(tmpdir(), "aviation-alert-"));
  const originalDirectory = process.cwd();
  t.after(() => {
    process.chdir(originalDirectory);
    rmSync(directory, { recursive: true, force: true });
  });
  process.chdir(directory);
  mkdirSync("checked");
  mkdirSync("reports");
  const { issues, comments, dependencies } = alertHarness();
  const now = Date.parse("2026-10-20T12:00:00Z");
  const succeeded = {
    CHECK_RESULT: "success",
    IMAGE_RESULT: "success",
    INGEST_RESULT: "success",
    TERRAIN_RESULT: "skipped",
    PURGE_RESULT: "success",
  };
  const failed = { ...succeeded, INGEST_RESULT: "failure" };

  writePublished(coveredStatus(0));
  writeReports([current, next], "failure");
  await notify(dependencies, failed, now);
  await notify(dependencies, failed, now);
  assert.equal(issues.length, 1);
  assert.deepEqual(issues[0].assignees, ["RISCfuture"]);
  assert.match(issues[0].body, /actions\/runs\/123/);
  assert.equal(comments.length, 0);

  writeReports([current, next], "withheld");
  await notify(dependencies, failed, now);
  assert.equal(comments.length, 1);
  assert.match(
    comments[0].body,
    /@RISCfuture.*nasr\/2026-10-29 \(withheld: incomplete release\)/,
  );

  writeReports([current, next], "success");
  writePublished(coveredStatus(3));
  await notify(dependencies, succeeded, now);
  assert.equal(issues[0].state, "closed");

  writeReports([current], "success");
  writePublished([{ source: "nasr", status: "available", version: current }]);
  await notify(
    dependencies,
    { ...succeeded, TERRAIN_RESULT: "failure" },
    Date.parse("2026-10-25T12:00:00Z"),
  );
  assert.equal(issues.length, 2);
  assert.match(issues[1].body, /nasr\/coverage \| expiring without successor/);
  assert.match(issues[1].body, /job\/terrain \| failure/);
});

function writeReports(releases, status) {
  writeFileSync("checked/nasr.json", JSON.stringify(releases));
  writeFileSync(
    "reports/navigation.json",
    JSON.stringify(
      releases.map((release) => ({ downloads: [release], status })),
    ),
  );
}

function writePublished(results) {
  writeFileSync(
    "published-status.json",
    JSON.stringify({ result: { structuredContent: { results } } }),
  );
}

function coveredStatus(parseErrors) {
  return [
    {
      source: "nasr",
      status: "available",
      version: current,
      nextVersion: {
        ...next,
        validation: { parse_errors: { count: parseErrors } },
      },
    },
  ];
}

function alertHarness() {
  const issues = [];
  const comments = [];
  const api = {
    listForRepo() {},
    async create(issue) {
      issues.push({ ...issue, number: issues.length + 1, state: "open" });
    },
    async update(update) {
      Object.assign(
        issues.find((issue) => issue.number === update.issue_number),
        update,
      );
    },
    async createComment(comment) {
      comments.push(comment);
    },
  };
  const dependencies = {
    github: {
      rest: { issues: api },
      paginate: async () => issues.filter((issue) => issue.state === "open"),
    },
    context: {
      repo: { owner: "RISCfuture", repo: "Aviation-MCP" },
      serverUrl: "https://github.com",
      runId: 123,
    },
    core: { info() {}, warning() {} },
  };
  return { issues, comments, dependencies };
}
