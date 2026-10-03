#!/usr/bin/env bash
set -euo pipefail
PM="0xFae375C9eA6636c40deB92DD91B7dbbF51BD3C68"
VBWBTC="0x0913DA6Da4b42f538B445599b46Bb4622342Cf52"
RPC="https://katana.drpc.org/"
API="https://explorer.katanarpc.com/api"
TOPIC0="$(cast keccak 'RegisterPool(address)')"

echo "topic0=$TOPIC0"
curl -fsSL --retry 4 --retry-delay 1   "$API?module=logs&action=getLogs&fromBlock=0&toBlock=latest&address=$PM&topic0=$TOPIC0"   -o /tmp/logs.json

cat /tmp/logs.json
echo

python3 - <<'PY' >/tmp/pools.txt
import json
d=json.load(open('/tmp/logs.json'))
for row in d.get('result',[]):
    topics=row.get('topics') or []
    if len(topics)>=2 and len(topics[1])==66:
        print('0x'+topics[1][-40:])
PY

echo "REGISTERED_POOLS"
cat /tmp/pools.txt

while read -r P; do
  [ -n "$P" ] || continue
  COLL="$(cast call "$P" 'collateralToken()(address)' --rpc-url "$RPC" 2>/dev/null || true)"
  echo "pool=$P collateral=$COLL"
  if [ "$(echo "$COLL"|tr '[:upper:]' '[:lower:]')" = "$(echo "$VBWBTC"|tr '[:upper:]' '[:lower:]')" ]; then
    echo "MATCHED_VBWBTC_POOL=$P"
    for sig in       'fxUSD()(address)'       'poolManager()(address)'       'configuration()(address)'       'priceOracle()(address)'       'getNextPositionId()(uint32)'       'getDebtRatioRange()(uint256,uint256)'       'getRebalanceRatios()(uint256,uint256)'       'getLiquidateRatios()(uint256,uint256)'       'isBorrowPaused()(bool)'       'isRedeemPaused()(bool)'; do
      echo "$sig => $(cast call "$P" "$sig" --rpc-url "$RPC" 2>/dev/null || true)"
    done
    echo "poolInfo => $(cast call "$PM" 'getPoolInfo(address)(uint256,uint256,uint256,uint256,uint256)' "$P" --rpc-url "$RPC" 2>/dev/null || true)"
  fi
done </tmp/pools.txt
