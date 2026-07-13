#!/usr/bin/env bash
# reconstruct_run_args round-trip (offline): every connection flag must reappear,
# with its value, in the generated systemd unit's ExecStart. This locks the
# single-source-of-truth CONN_PARAMS table so a future edit cannot silently drop a
# flag from the installed service.
set -u
. "$(dirname "$0")/lib.sh"
echo "[test_reconstruct] connection args round-trip into the unit"

unit="$("$PY" "$PROG" print-unit \
    --user bob --jump-host jh --jump-port 2200 --jump-user gw \
    --remote-host rh --remote-ssh-port 2022 --key /k/id \
    --socks-port 3335 --server-alive-interval 45 --max-retries 7 \
    --stable-after 90 --backoff-base 3 --backoff-cap 40 \
    -J -o Compression=yes -F /etc/ssh/x.conf)"

exec_line="$(printf '%s\n' "$unit" | grep '^ExecStart=')"
[ -n "$exec_line" ] && ok "unit has an ExecStart line" || bad "no ExecStart line"
assert_contains "ExecStart runs the 'run' subcommand" "$exec_line" "run --user"

# Every uniform connection value-arg round-trips with its non-default value ...
for pair in \
    "--user bob" "--jump-host jh" "--jump-port 2200" \
    "--remote-host rh" "--remote-ssh-port 2022" "--key /k/id" \
    "--socks-port 3335" "--server-alive-interval 45" "--max-retries 7" \
    "--stable-after 90" "--backoff-base 3" "--backoff-cap 40"; do
  assert_contains "unit carries [$pair]" "$exec_line" "$pair"
done

# ... and so do the special args.
assert_contains "unit carries --jump"        "$exec_line" "--jump"
assert_contains "unit carries --jump-user"   "$exec_line" "--jump-user gw"
assert_contains "unit carries --ssh-option"  "$exec_line" "--ssh-option Compression=yes"
assert_contains "unit carries --ssh-config"  "$exec_line" "--ssh-config /etc/ssh/x.conf"

finish
