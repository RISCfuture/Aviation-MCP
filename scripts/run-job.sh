#!/bin/sh
# Runs a job command. When the command dies by a signal, sends the crash it stored, allowing
# up to 15 seconds, before exiting with the command's status.

"$@"
status=$?
if [ "$status" -gt 128 ]; then
  timeout 15 /app/aviation-mcp sentry-flush
fi
exit "$status"
