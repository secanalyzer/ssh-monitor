#!/usr/bin/env bash
# Retry policy, using a fake `ssh` on PATH (no real network):
#  - exhaustion after --max-retries consecutive failures -> exit 3
#  - a session up >= --stable-after resets the retry budget (never exhausts)
set -u
. "$(dirname "$0")/lib.sh"
echo "[test_retry] reconnect retry policy"
setup_env

FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"

# (a) fake ssh that always fails immediately
cat > "$FAKEBIN/ssh" <<'EOF'
#!/usr/bin/env bash
exit 255
EOF
chmod +x "$FAKEBIN/ssh"

PATH="$FAKEBIN:$PATH" "$PY" "$PROG" run --socks-port "$SOCKS_PORT" \
    --max-retries 3 --backoff-base 1 --backoff-cap 1 > "$WORK/exhaust.log" 2>&1
rc=$?
assert_eq "exhaustion exit code is 3" "$rc" "3"
assert_contains "logged exhaustion" "$(cat "$WORK/exhaust.log")" "exhausted 3 retries"

# (b) fake ssh that stays up 2s then drops -> counts as healthy (stable-after=1),
#     so the counter keeps resetting and never exhausts despite max-retries=2.
cat > "$FAKEBIN/ssh" <<'EOF'
#!/usr/bin/env bash
sleep 2
exit 1
EOF
chmod +x "$FAKEBIN/ssh"

PATH="$FAKEBIN:$PATH" "$PY" "$PROG" run --socks-port "$SOCKS_PORT" \
    --max-retries 2 --stable-after 1 --backoff-base 1 --backoff-cap 1 \
    > "$WORK/stable.log" 2>&1 &
pid=$!; _PIDS+=("$pid")
sleep 8
kill -TERM "$pid"; wait "$pid" 2>/dev/null
log="$(cat "$WORK/stable.log")"
assert_contains     "counter resets on stable session" "$log" "resetting retry counter"
assert_not_contains "never exhausts while stable"       "$log" "giving up"

finish
