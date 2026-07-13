#!/usr/bin/env bash
# End-to-end -J JUMP mode: local -> [jump 127.0.0.1:JUMP_PORT] -> 127.0.0.1:SSHD_PORT
# -> SOCKS5. Two distinct sshd hops (a jump host must differ from the target, or
# OpenSSH rejects it as a loop). Host-key/identity for BOTH hops come from -F,
# because -o options do NOT propagate to the -J inner connection.
set -u
. "$(dirname "$0")/lib.sh"
echo "[test_tunnel_jump] real SOCKS5 tunnel (-J jump)"
setup_env
start_sshd "$SSHD_PORT" remote || { finish; exit 1; }
start_sshd "$JUMP_PORT" jump   || { finish; exit 1; }
start_origin "$ORIGIN_PORT"    || { finish; exit 1; }

start_tunnel -J -F "$WORK/ssh_config" \
    --jump-host 127.0.0.1 --jump-port "$JUMP_PORT" \
    --remote-host 127.0.0.1 --remote-ssh-port "$SSHD_PORT" --user "$USER" \
    --key "$WORK/clientkey" --socks-port "$SOCKS_PORT2" >/dev/null
_wait_port "$SOCKS_PORT2" && ok "SOCKS port $SOCKS_PORT2 is listening" \
                          || bad "SOCKS port never opened"

body="$(socks_fetch "$SOCKS_PORT2")"
assert_eq "data flows through the 2-hop jump tunnel" "$body" "$PROBE"

# the jump sshd must have logged an accepted login -> the jump hop was really used
accepted="$(grep -c 'Accepted publickey' "$WORK/jump.log" 2>/dev/null)"
awk "BEGIN{exit !($accepted >= 1)}" && ok "jump host was traversed ($accepted logins)" \
                                    || bad "jump host not used (0 logins)"

finish
