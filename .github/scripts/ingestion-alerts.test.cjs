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

test("attempts the upcoming pair after a current-cycle failure and reports both outcomes", (t) => {
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
    '#!/usr/bin/env bash\nset -euo pipefail\nplan=$(jq -rn --arg encoded "$2" \'$encoded | @base64d\')\nprintf "%s\\n" "$plan" >> calls.jsonl\n[[ $(jq -r ".[0].cycle" <<< "$plan") != 2026-10-01 ]]\n',
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
    reports.map((report) => report.status),
    ["failure", "success"],
  );
  const calls = readFileSync(path.join(directory, "calls.jsonl"), "utf8");
  assert.match(calls, /2026-10-29/);
  assert.equal(reports[1].downloads.length, 2);
});

test("alerts once, notifies new failing cycles, and closes the issue after recovery", async (t) => {
  const directory = mkdtempSync(path.join(tmpdir(), "aviation-alert-"));
  const originalDirectory = process.cwd();
  t.after(() => {
    process.chdir(originalDirectory);
    rmSync(directory, { recursive: true, force: true });
  });
  process.chdir(directory);
  mkdirSync("checked");
  mkdirSync("reports");
  const issues = [];
  const comments = [];
  const api = {
    listForRepo() {},
    async create(issue) {
      issues.push({ ...issue, number: 1, state: "open" });
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
  const writeReports = (releases, status) => {
    writeFileSync("checked/nasr.json", JSON.stringify(releases));
    writeFileSync(
      "reports/navigation.json",
      JSON.stringify(
        releases.map((release) => ({ downloads: [release], status })),
      ),
    );
  };
  writeReports([current], "failure");
  const failed = { CHECK_RESULT: "success", INGEST_RESULT: "failure" };
  await notify(dependencies, failed);
  await notify(dependencies, failed);
  assert.equal(issues.length, 1);
  assert.deepEqual(issues[0].assignees, ["RISCfuture"]);
  assert.match(issues[0].body, /actions\/runs\/123/);
  assert.equal(comments.length, 0);
  writeReports([current, next], "failure");
  await notify(dependencies, failed);
  await notify(dependencies, failed);
  assert.equal(comments.length, 1);
  assert.match(comments[0].body, /@RISCfuture.*nasr\/2026-10-29/);
  writeReports([current, next], "success");
  const writePublished = (count) =>
    writeFileSync(
      "published-status.json",
      JSON.stringify({
        result: {
          structuredContent: {
            results: [
              {
                version: current,
                nextVersion: {
                  ...next,
                  validation: { parse_errors: { count } },
                },
              },
            ],
          },
        },
      }),
    );
  writePublished(3);
  await notify(dependencies, {
    CHECK_RESULT: "success",
    INGEST_RESULT: "success",
  });
  assert.equal(issues[0].state, "open");
  assert.match(issues[0].body, /published with gaps \| 3/);
  writePublished(0);
  await notify(dependencies, {
    CHECK_RESULT: "success",
    INGEST_RESULT: "success",
  });
  assert.equal(issues[0].state, "closed");
});
