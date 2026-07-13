#!/usr/bin/env bash
# Command construction (dry-run, no network): parameterization, -J toggle,
# extra -o passthrough + override, -F flag.
set -u
. "$(dirname "$0")/lib.sh"
echo "[test_cmd] ssh command construction"

PY="$(command -v python3)"
dry() { "$PY" "$PROG" run --dry-run "$@"; }

# 1. defaults, direct (no -J): must match the reference command's essentials.
out="$(dry)"
assert_contains "default key"        "$out" "-i /home/user/.ssh/id_rsa"
assert_contains "default SOCKS port" "$out" "-D 23456"
assert_contains "default remote"     "$out" "-p 22 user@server1"
assert_contains "ServerAliveInterval" "$out" "-o ServerAliveInterval=30"
assert_not_contains "no jump when -J omitted" "$out" "-J "

# 2. -J enables the jump proxy.
out="$(dry -J)"
assert_contains "jump proxy present" "$out" "-J user@jumpbox:5522"

# 3. alternate ports + params are honoured; --jump-user defaults to --user.
out="$(dry -J --socks-port 3335 --user bob --jump-host jh --jump-port 2200 \
          --remote-host rh --remote-ssh-port 2022)"
assert_contains "alt socks"  "$out" "-D 3335"
assert_contains "alt jump"   "$out" "-J bob@jh:2200"
assert_contains "alt remote" "$out" "-p 2022 bob@rh"

# 3b. --jump-user overrides the jump login without touching the target login.
out="$(dry -J --user bob --jump-user gw --jump-host jh --jump-port 2200)"
assert_contains "jump user honoured"     "$out" "-J gw@jh:2200"
assert_contains "target user unaffected" "$out" "bob@server1"

# 4. user -o overrides the built-in default (ssh is first-value-wins).
out="$(dry -o StrictHostKeyChecking=yes)"
assert_contains     "user option present" "$out" "-o StrictHostKeyChecking=yes"
assert_not_contains "built-in dropped"    "$out" "StrictHostKeyChecking=accept-new"

# 5. -F config flag is emitted.
out="$(dry -J -F /tmp/x.conf)"
assert_contains "ssh -F present" "$out" "-F /tmp/x.conf"

finish
