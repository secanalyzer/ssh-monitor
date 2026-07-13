#!/usr/bin/env bash
# Auto-reconnect after a REAL ssh drop: fetch works, kill the live ssh child,
# the supervisor reconnects (new pid), and a fetch works again.
set -u
. "$(dirname "$0")/lib.sh"
echo "[test_reconnect] auto-reconnect after a real drop"
setup_env
start_sshd  "$SSHD_PORT" remote || { finish; exit 1; }
start_origin "$ORIGIN_PORT"      || { finish; exit 1; }

start_tunnel --remote-host 127.0.0.1 --remote-ssh-port "$SSHD_PORT" --user "$USER" \
    --key "$WORK/clientkey" --socks-port "$SOCKS_PORT" --backoff-base 1 --backoff-cap 1 \
    -o UserKnownHostsFile="$WORK/known_hosts" -o StrictHostKeyChecking=no >/dev/null
_wait_port "$SOCKS_PORT" || { bad "SOCKS port never opened"; finish; exit 1; }

body="$(socks_fetch "$SOCKS_PORT")"
assert_eq "fetch #1 (initial tunnel)" "$body" "$PROBE"

# bracket => the pattern never matches this script's own command line
child1="$(pgrep -f "clientkey -D ${SOCKS_PORT}[^0-9]" | head -1)"
[ -n "$child1" ] && ok "found live ssh child ($child1)" || bad "no ssh child to kill"
kill -9 "$child1" 2>/dev/null

# wait for the supervisor to notice + reconnect
sleep 5
child2="$(pgrep -f "clientkey -D ${SOCKS_PORT}[^0-9]" | head -1)"
[ -n "$child2" ] && [ "$child2" != "$child1" ] \
    && ok "reconnected with a new ssh child ($child1 -> $child2)" \
    || bad "did not reconnect (child1=$child1 child2=$child2)"

body2="$(socks_fetch "$SOCKS_PORT")"
assert_eq "fetch #2 (re-established tunnel)" "$body2" "$PROBE"

finish
