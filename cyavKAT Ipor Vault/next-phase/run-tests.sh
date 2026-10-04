#!/usr/bin/env bash
# Runs the Phase 2 Katana fork suite and prints a short summary (pass/fail counts, failing tests with their decoded
# revert, and any src contract over 22 KB). Read-only: forge test on a local fork, never broadcasts.
#
#   bash run-tests.sh                 # whole suite
#   bash run-tests.sh test_lp         # only tests whose name contains "test_lp"
#   bash run-tests.sh <name> trace    # one test with the trace lines around the revert
set -u
cd "$(dirname "$0")"
export PATH="$PATH:$HOME/.foundry/bin"
# KATANA_RPC_URL: set it in the environment, or put KATANA_RPC_URL=... in a .env file next to this script (never commit it).
[ -z "${KATANA_RPC_URL:-}" ] && [ -f .env ] && export KATANA_RPC_URL=$(grep -E '^KATANA_RPC_URL=' .env | cut -d= -f2- | tr -d '"')
MATCH="${1:-}"
MODE="${2:-}"
OUT=$(mktemp)

run() {
  export FORK_BLOCK=$(( $(cast block-number --rpc-url "$KATANA_RPC_URL") - 30 ))
  local verbosity="-vv"; [ "$MODE" = "trace" ] && verbosity="-vvvv"
  if [ -n "$MATCH" ]; then
    forge test --match-test "$MATCH" $verbosity > "$OUT" 2>&1
  else
    forge test $verbosity > "$OUT" 2>&1
  fi
}

run
# The free RPC sometimes has not seen the newest block yet: retry once with a fresh fork block.
if grep -q "Unknown block" "$OUT"; then sleep 5; run; fi

echo "fork block: $FORK_BLOCK"
grep -E "^Ran [0-9]+ test suites|^Suite result|^Error: Compiler run failed" "$OUT" | head -6
grep -E "^\[FAIL" "$OUT" | while read -r line; do
  echo "$line" | cut -c1-240
  sel=$(echo "$line" | grep -oE "custom error 0x[0-9a-f]{8}" | grep -oE "0x[0-9a-f]{8}")
  [ -n "$sel" ] && echo "    decoded: $(cast 4byte "$sel" 2>/dev/null || echo unknown) ($sel)"
done
grep -E "^Error \(|^error\[" -A3 "$OUT" | head -20

if [ "$MODE" = "trace" ]; then
  L=$(grep -nE "\[Revert\]" "$OUT" | grep -v "custom error 0x00000000" | tail -1 | cut -d: -f1)
  [ -n "$L" ] && sed -n "$((L > 12 ? L - 12 : 1)),$((L + 2))p" "$OUT" | cut -c1-220
fi

forge build --sizes 2>/dev/null | grep -E "^\| CurveYield" | awk -F'|' '{gsub(/ /,"",$2); gsub(/[ ,]/,"",$3); if ($3+0 > 22000) print "SIZE WARNING:", $2, $3, "bytes (limit 24576)"}'
rm -f "$OUT"
