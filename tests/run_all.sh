#!/usr/bin/env bash
# Run the full ssh_monitor test suite and report pass/fail counts.
#
#   bash tests/run_all.sh            # run every test
#   bash tests/run_all.sh test_cmd   # run a subset by name (globbed)
#
# Requires: bash, ssh, sshd, ssh-keygen, curl, ss, python3 (test HTTP origin only). The systemd test
# self-skips if `systemctl --user` is unavailable.
set -u
cd "$(dirname "$0")"

# Order: cheap/offline first, network + systemd last.
DEFAULT=(test_cmd test_reconstruct test_custom_cmd test_retry test_shutdown
         test_tunnel_direct test_tunnel_jump test_reconnect test_systemd)

if [ "$#" -gt 0 ]; then
  SELECT=()
  for pat in "$@"; do for f in ${pat%.sh}*.sh; do SELECT+=("${f%.sh}"); done; done
else
  SELECT=("${DEFAULT[@]}")
fi

tp=0; tf=0; failed=()
for name in "${SELECT[@]}"; do
  f="$name.sh"; [ -f "$f" ] || { echo "?? missing $f"; continue; }
  echo "==================================================================="
  # Each test prints its own PASS/FAIL lines and a summary line.
  out="$(bash "$f" 2>&1)"; rc=$?
  echo "$out"
  # tally from the per-test summary line "--- N passed, M failed ---"
  p=$(sed -n 's/.*--- \([0-9]*\) passed, \([0-9]*\) failed ---.*/\1/p' <<<"$out" | tail -1)
  m=$(sed -n 's/.*--- \([0-9]*\) passed, \([0-9]*\) failed ---.*/\2/p' <<<"$out" | tail -1)
  tp=$((tp + ${p:-0})); tf=$((tf + ${m:-0}))
  [ "$rc" -eq 0 ] || failed+=("$name")
done

echo "==================================================================="
echo "TOTAL: $tp passed, $tf failed across ${#SELECT[@]} test files"
if [ "${#failed[@]}" -gt 0 ]; then
  echo "FAILED FILES: ${failed[*]}"; exit 1
fi
echo "ALL GREEN"
