#!/usr/bin/env bash
# Custom-command supervision + --once short-lived mode (offline, no network):
#  - a trailing command replaces the built-in ssh command verbatim
#  - --once runs the command exactly once and propagates its exit status
#  - without --once a custom command gets the normal monitor/retry loop
#  - --once and the custom command round-trip into the systemd unit
set -u
. "$(dirname "$0")/lib.sh"
echo "[test_custom_cmd] arbitrary ssh command + --once"
setup_env

# 1. dry-run shows the custom command verbatim: no built-in flags injected.
out="$("$PY" "$PROG" run --dry-run -- ssh -vNT -D 1080 alice@example)"
assert_eq "custom command verbatim (after --)" "$out" "ssh -vNT -D 1080 alice@example"
out="$("$PY" "$PROG" run --dry-run ssh -N host)"
assert_eq "custom command verbatim (no --)" "$out" "ssh -N host"

# 2. --once: run exactly once, exit 0, log that no restart happens.
"$PY" "$PROG" run --once -- sh -c "echo ran >> '$WORK/marker'" \
    > "$WORK/once.log" 2>&1
assert_eq "--once success exits 0" "$?" "0"
assert_eq "--once ran exactly once" "$(wc -l < "$WORK/marker" | tr -d ' ')" "1"
assert_contains "--once logged no-restart" "$(cat "$WORK/once.log")" "not restarting"

# 2b. --once propagates a nonzero exit status.
"$PY" "$PROG" run --once -- sh -c 'exit 7' > /dev/null 2>&1
assert_eq "--once propagates rc" "$?" "7"

# 3. without --once, a failing custom command is monitored: retried with
#    backoff, then exhausts the retry budget (exit 3) like the built-in tunnel.
"$PY" "$PROG" run --max-retries 2 --backoff-base 1 --backoff-cap 1 \
    -- sh -c "echo run >> '$WORK/marker2'; exit 1" > "$WORK/mon.log" 2>&1
rc=$?
assert_eq "monitored custom cmd exhausts -> 3" "$rc" "3"
assert_eq "monitored custom cmd restarted (3 attempts)" \
          "$(wc -l < "$WORK/marker2" | tr -d ' ')" "3"

# 4. systemd unit round-trip: --once + the command land in ExecStart, and a
#    --once unit must not be restarted by systemd either.
unit="$("$PY" "$PROG" print-unit --once -- ssh -W host:22 target)"
exec_line="$(printf '%s\n' "$unit" | grep '^ExecStart=')"
assert_contains "unit carries --once"       "$exec_line" "--once"
assert_contains "unit carries the command"  "$exec_line" "-- ssh -W host:22 target"
assert_contains "once unit does not restart" "$unit" "Restart=no"
unit="$("$PY" "$PROG" print-unit -- ssh -W host:22 target)"
assert_contains "monitored unit still restarts" "$unit" "Restart=on-failure"

finish
