const DAY = 86_400_000;

/** The cron expression of the regular ingestion run. */
const REGULAR_SCHEDULE = "17 */6 * * *";
/** The cron expression of the frequent polling run around DOF releases. */
const RELEASE_WINDOW_SCHEDULE = "7,27,47 * * * *";
/** A DOF release date; the FAA releases a DOF every 56 days. */
const DOF_REFERENCE_RELEASE = Date.UTC(2025, 8, 2);
const DOF_CADENCE = 56 * DAY;
/** Polling starts this long before a scheduled DOF release, in case the FAA posts it early. */
const RELEASE_WINDOW_LEAD = 2 * DAY;
/** Polling stops this long after a scheduled DOF release if it is still unpublished. */
const RELEASE_WINDOW_TRAIL = 14 * DAY;
/** Events that only check sources, without dispatching ingestion. */
const CHECK_ONLY_EVENTS = new Set(["push", "pull_request"]);
/** Terrain and purge maintenance run only in the regular run starting before this UTC hour. */
const MAINTENANCE_HOUR = 6;

/** Returns the scheduled DOF release whose polling window contains `now`, as YYYY-MM-DD. */
function dofReleaseWindow(now) {
  const cycles = Math.floor(
    (now - DOF_REFERENCE_RELEASE + RELEASE_WINDOW_LEAD) / DOF_CADENCE,
  );
  const release = DOF_REFERENCE_RELEASE + cycles * DOF_CADENCE;
  if (
    now < release - RELEASE_WINDOW_LEAD ||
    now >= release + RELEASE_WINDOW_TRAIL
  )
    return "";
  return new Date(release).toISOString().slice(0, 10);
}

/**
 * Decides what one workflow run does. `check` discovers releases, `ingest` dispatches
 * unpublished ones and raises alerts, and `maintenance` publishes terrain and purges.
 * A release-window run proceeds only while `dofRelease` is unpublished.
 */
function plan({ eventName, schedule, now }) {
  const run = (check, ingest, maintenance, dofRelease = "") => ({
    check,
    ingest,
    maintenance,
    dofRelease,
  });
  if (CHECK_ONLY_EVENTS.has(eventName)) return run(true, false, false);
  if (eventName === "workflow_dispatch") return run(true, true, true);
  if (schedule === REGULAR_SCHEDULE)
    return run(true, true, new Date(now).getUTCHours() < MAINTENANCE_HOUR);
  if (schedule === RELEASE_WINDOW_SCHEDULE) {
    const dofRelease = dofReleaseWindow(now);
    return dofRelease
      ? run(true, true, false, dofRelease)
      : run(false, false, false);
  }
  return run(false, false, false);
}

module.exports = {
  REGULAR_SCHEDULE,
  RELEASE_WINDOW_SCHEDULE,
  plan,
};
