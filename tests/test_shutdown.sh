#!/usr/bin/env bash
# Clean shutdown on SIGTERM (fake ssh, no network): supervisor exits 0 quickly
# and leaves no orphaned ssh child.
set -u
. "$(dirname "$0")/lib.sh"
echo "[test_shutdown] clean SIGTERM teardown"
setup_env

FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
# fake ssh that mimics a live tunnel
cat > "$FAKEBIN/ssh" <<'EOF'
#!/usr/bin/env bash
exec sleep 3000
EOF
chmod +x "$FAKEBIN/ssh"

PATH="$FAKEBIN:$PATH" "$PY" "$PROG" run --socks-port "$SOCKS_PORT" \
    > "$WORK/shut.log" 2>&1 &
pid=$!; _PIDS+=("$pid")
sleep 1.5

# child tunnel present?
child="$(pgrep -P "$pid" 2>/dev/null; pgrep -f "sleep 300[0]" 2>/dev/null | head -1)"
[ -n "$child" ] && ok "tunnel child running before stop" || bad "no tunnel child before stop"

t0=$(date +%s.%N)
kill -TERM "$pid"; wait "$pid"; rc=$?
t1=$(date +%s.%N)
elapsed=$(awk "BEGIN{print $t1-$t0}")

assert_eq "clean exit code 0" "$rc" "0"
awk "BEGIN{exit !($elapsed < 3)}" && ok "shutdown < 3s (was ${elapsed}s)" \
                                  || bad "shutdown too slow (${elapsed}s)"
sleep 0.5
pgrep -f "sleep 300[0]" >/dev/null && bad "orphaned tunnel child remains" \
                                   || ok "no orphaned tunnel child"
assert_contains "no forced SIGKILL needed" "$(cat "$WORK/shut.log")" "stopped cleanly"

finish
