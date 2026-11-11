#!/bin/sh
# Runs a job command. When the command dies by a signal, waits up to 15 seconds for
# crashpad_handler to upload the crash before exiting with the command's status.

# The kernel truncates a process's comm to 15 characters.
crashpad_running() {
  grep -qsx 'crashpad_handle' /proc/[0-9]*/comm
}

"$@"
status=$?
if [ "$status" -gt 128 ]; then
  remaining=15
  while [ "$remaining" -gt 0 ] && crashpad_running; do
    sleep 1
    remaining=$((remaining - 1))
  done
fi
exit "$status"
