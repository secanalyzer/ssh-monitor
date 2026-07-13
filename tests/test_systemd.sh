#!/usr/bin/env bash
# Real systemd (`--user`) lifecycle: install a service that tunnels to the
# throwaway localhost sshd, fetch THROUGH the service-managed tunnel, then stop
# (port closes, no orphan) and uninstall. Skips cleanly if user systemd is
# unavailable (e.g. headless with no user manager).
set -u
. "$(dirname "$0")/lib.sh"
echo "[test_systemd] real --user service lifecycle"

SERVICE="ssh-socks-selftest"

if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "  SKIP: 'systemctl --user' not available in this environment"
  echo "  --- 0 passed, 0 failed ---"; exit 0
fi

setup_env
start_sshd  "$SSHD_PORT" remote || { finish; exit 1; }
start_origin "$ORIGIN_PORT"      || { finish; exit 1; }

svc_cleanup() {
  systemctl --user stop "$SERVICE" 2>/dev/null
  "$PY" "$PROG" uninstall --user-scope --service-name "$SERVICE" >/dev/null 2>&1
}
trap 'svc_cleanup; teardown' EXIT

"$PY" "$PROG" install --user-scope --service-name "$SERVICE" \
    --remote-host 127.0.0.1 --remote-ssh-port "$SSHD_PORT" --user "$USER" \
    --key "$WORK/clientkey" --socks-port "$SOCKS_PORT" \
    -o UserKnownHostsFile="$WORK/known_hosts" -o StrictHostKeyChecking=no \
    >/dev/null 2>&1

_wait_port "$SOCKS_PORT" 20
assert_eq "service is active" "$(systemctl --user is-active "$SERVICE")" "active"
assert_eq "service is enabled" "$(systemctl --user is-enabled "$SERVICE")" "enabled"
assert_eq "fetch through service-managed tunnel" "$(socks_fetch "$SOCKS_PORT")" "$PROBE"

systemctl --user stop "$SERVICE"
sleep 1
port_listening "$SOCKS_PORT" && bad "SOCKS port still open after stop" \
                             || ok "SOCKS port closed after stop"
pgrep -f "clientkey -D ${SOCKS_PORT}[^0-9]" >/dev/null \
    && bad "orphaned ssh after stop" || ok "no orphaned ssh after stop"

"$PY" "$PROG" uninstall --user-scope --service-name "$SERVICE" >/dev/null 2>&1
assert_eq "service inactive after uninstall" \
    "$(systemctl --user is-active "$SERVICE" 2>/dev/null)" "inactive"

finish
