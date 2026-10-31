const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  REGULAR_SCHEDULE,
  RELEASE_WINDOW_SCHEDULE,
  plan,
} = require("./ingestion-plan.cjs");

test("polls frequently only around a scheduled DOF release", () => {
  const poll = (time) =>
    plan({
      eventName: "schedule",
      schedule: RELEASE_WINDOW_SCHEDULE,
      now: Date.parse(time),
    });
  assert.deepEqual(poll("2026-11-10T12:00:00Z"), {
    check: false,
    ingest: false,
    maintenance: false,
    dofRelease: "",
  });
  for (const time of [
    "2026-11-22T00:00:00Z",
    "2026-11-24T05:00:00Z",
    "2026-12-07T23:00:00Z",
  ])
    assert.deepEqual(poll(time), {
      check: true,
      ingest: true,
      maintenance: false,
      dofRelease: "2026-11-24",
    });
  assert.equal(poll("2026-12-08T00:00:00Z").check, false);
});

test("runs maintenance once a day and only checks on push or pull request", () => {
  const regular = (time) =>
    plan({
      eventName: "schedule",
      schedule: REGULAR_SCHEDULE,
      now: Date.parse(time),
    });
  assert.equal(regular("2026-11-01T00:40:00Z").maintenance, true);
  assert.equal(regular("2026-11-01T06:40:00Z").maintenance, false);
  assert.equal(regular("2026-11-01T06:40:00Z").ingest, true);
  for (const eventName of ["push", "pull_request"]) {
    assert.deepEqual(plan({ eventName, now: 0 }), {
      check: true,
      ingest: false,
      maintenance: false,
      dofRelease: "",
    });
  }
});
