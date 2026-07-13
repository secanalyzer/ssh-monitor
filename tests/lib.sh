#!/usr/bin/env bash
# Shared harness for ssh_monitor tests.
#
# Provides: a throwaway sshd (optionally a second one as a jump host), a local
# HTTP "origin" server behind the tunnel, throwaway ssh keys, an ssh_config that
# also configures the -J jump hop, plus assertion + teardown helpers.
#
# All heavy/background processes are launched with `nice -n 19` and torn down on
# EXIT. Nothing here touches the user's real ~/.ssh or the system sshd.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROG="$(cd "$HERE/.." && pwd)/ssh_monitor.py"
PY="$(command -v python3)"

# Ports (overridable via env to avoid collisions).
: "${SSHD_PORT:=2222}"      # stands in for the remote host
: "${JUMP_PORT:=2223}"      # distinct jump host
: "${ORIGIN_PORT:=8899}"    # HTTP origin behind the tunnel
: "${SOCKS_PORT:=3335}"     # local SOCKS5 proxy
: "${SOCKS_PORT2:=23459}"   # second SOCKS5 proxy (jump tests)

PASS=0; FAIL=0
_PIDS=()          # background processes to SIGTERM on teardown
PROBE="hello-through-socks"

# ---- assertions ----------------------------------------------------------
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

assert_eq() { # desc  actual  expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi
}
assert_contains() { # desc  haystack  needle
  case "$2" in *"$3"*) ok "$1";; *) bad "$1 (missing [$3])";; esac
}
assert_not_contains() { # desc  haystack  needle
  case "$2" in *"$3"*) bad "$1 (unexpected [$3])";; *) ok "$1";; esac
}
finish() { echo "  --- $PASS passed, $FAIL failed ---"; [ "$FAIL" -eq 0 ]; }

# ---- environment ---------------------------------------------------------
setup_env() {
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/sst-test.XXXXXX")"
  trap teardown EXIT
  ssh-keygen -t ed25519 -f "$WORK/hostkey"   -N '' -q -C host
  ssh-keygen -t ed25519 -f "$WORK/clientkey" -N '' -q -C client
  cp "$WORK/clientkey.pub" "$WORK/authorized_keys"; chmod 600 "$WORK/authorized_keys"
  : > "$WORK/known_hosts"

  # ssh_config that drives BOTH the outer and the -J inner connection.
  mkdir -p "$WORK/dot-ssh"; chmod 700 "$WORK/dot-ssh"
  cat > "$WORK/ssh_config" <<EOF
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    BatchMode yes
    IdentityFile $WORK/clientkey
EOF
  chmod 600 "$WORK/ssh_config"
}

_sshd_conf() { # port  pidfile  logfile
  cat <<EOF
Port $1
ListenAddress 127.0.0.1
HostKey $WORK/hostkey
PidFile $2
AuthorizedKeysFile $WORK/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
AllowTcpForwarding yes
LogLevel VERBOSE
EOF
}

start_sshd() { # port  name
  local port="$1" name="$2"
  _sshd_conf "$port" "$WORK/$name.pid" "$WORK/$name.log" > "$WORK/$name.conf"
  nice -n 19 /usr/sbin/sshd -D -f "$WORK/$name.conf" -E "$WORK/$name.log" &
  _PIDS+=($!)
  _wait_port "$port" || { echo "sshd $name failed to listen on $port"; cat "$WORK/$name.log"; return 1; }
}

start_origin() { # port
  local port="$1"
  mkdir -p "$WORK/web"; echo "$PROBE" > "$WORK/web/probe.txt"
  ( cd "$WORK/web" && exec nice -n 19 "$PY" -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  _PIDS+=($!)
  _wait_port "$port" || { echo "origin failed to listen on $port"; return 1; }
}

# Start the supervisor in the background; echoes its PID.
start_tunnel() { # args...
  "$PY" "$PROG" run "$@" >>"$WORK/tunnel.log" 2>&1 &
  local pid=$!; _PIDS+=("$pid"); echo "$pid"
}

# Fetch the origin THROUGH the SOCKS5 proxy; echoes the body.
socks_fetch() { # socks_port
  curl -s --max-time 5 --socks5-hostname "127.0.0.1:$1" "http://127.0.0.1:$ORIGIN_PORT/probe.txt"
}

# Match the port on ANY local address: a user ~/.ssh/config with
# `GatewayPorts yes` makes `ssh -D` bind 0.0.0.0 instead of 127.0.0.1.
_wait_port() { # port  [tries]
  local port="$1" tries="${2:-40}"
  while [ "$tries" -gt 0 ]; do
    port_listening "$port" && return 0
    sleep 0.25; tries=$((tries-1))
  done
  return 1
}

port_listening() { ss -ltn 2>/dev/null | grep -q ":$1 "; }

teardown() {
  local pid
  for pid in "${_PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  # belt-and-suspenders: reap any stray tunnel ssh children (bracket => never
  # matches this script's own command line).
  pkill -f "clientkey -D ${SOCKS_PORT}[^0-9]"  2>/dev/null
  pkill -f "clientkey -D ${SOCKS_PORT2}[^0-9]" 2>/dev/null
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}
