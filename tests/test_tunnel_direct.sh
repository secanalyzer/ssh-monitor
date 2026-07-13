#!/usr/bin/env bash
# End-to-end DIRECT mode against a throwaway localhost sshd: real `ssh -D`, then
# fetch the origin THROUGH the SOCKS5 proxy.
set -u
. "$(dirname "$0")/lib.sh"
echo "[test_tunnel_direct] real SOCKS5 tunnel (direct)"
setup_env
start_sshd  "$SSHD_PORT" remote || { finish; exit 1; }
start_origin "$ORIGIN_PORT"       || { finish; exit 1; }

start_tunnel --remote-host 127.0.0.1 --remote-ssh-port "$SSHD_PORT" --user "$USER" \
    --key "$WORK/clientkey" --socks-port "$SOCKS_PORT" \
    -o UserKnownHostsFile="$WORK/known_hosts" -o StrictHostKeyChecking=no >/dev/null
_wait_port "$SOCKS_PORT" && ok "SOCKS port $SOCKS_PORT is listening" \
                         || bad "SOCKS port never opened"

body="$(socks_fetch "$SOCKS_PORT")"
assert_eq "data flows through the tunnel" "$body" "$PROBE"

# a second request over the same tunnel
body2="$(socks_fetch "$SOCKS_PORT")"
assert_eq "second request succeeds" "$body2" "$PROBE"

finish
