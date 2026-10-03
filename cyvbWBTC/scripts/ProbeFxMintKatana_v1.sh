#!/usr/bin/env bash
set -euo pipefail

RPC="${KATANA_RPC_URL:-https://katana.drpc.org/}"
FXUSD="0x1364b238C668A2dec1294174e4798E8c09979f86"
VBWBTC="0x0913DA6Da4b42f538B445599b46Bb4622342Cf52"
VBUSDC="0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36"
SUSHI_FACTORY="0x203e8740894c8955cB8950759876d7E7E45E04c1"
CURVEYIELD_ROUTER="0x01F9894f92ea9224fECc8C35482E20a05De13582"

echo "chain_id=$(cast chain-id --rpc-url "$RPC")"
echo "block=$(cast block-number --rpc-url "$RPC")"
echo "fxUSD=$FXUSD"

PM="$(cast call "$FXUSD" "poolManager()(address)" --rpc-url "$RPC")"
echo "poolManager=$PM"

for sig in   "fxUSD()(address)"   "fxBASE()(address)"   "configuration()(address)"   "counterparty()(address)"   "whitelist()(address)"   "permissionedLiquidationThreshold()(uint256)"; do
  echo "PM $sig => $(cast call "$PM" "$sig" --rpc-url "$RPC" 2>/dev/null || true)"
done

echo "PM getTokenScalingFactor(vbWBTC) => $(cast call "$PM" "getTokenScalingFactor(address)(uint256)" "$VBWBTC" --rpc-url "$RPC")"

for fee in 100 500 3000 10000; do
  pool="$(cast call "$SUSHI_FACTORY" "getPool(address,address,uint24)(address)" "$FXUSD" "$VBUSDC" "$fee" --rpc-url "$RPC" 2>/dev/null || true)"
  echo "SUSHI_POOL fxUSD/vbUSDC fee=$fee => $pool"
done

echo "CurveYield router fxUSD->vbUSDC route => $(cast call "$CURVEYIELD_ROUTER" "routeFor(address,address)(bytes)" "$FXUSD" "$VBUSDC" --rpc-url "$RPC" 2>/dev/null || true)"

# Pull RegisterPool events. First try one full-range query; fall back to 250k-block chunks.
LATEST="$(cast block-number --rpc-url "$RPC")"
TMP="$(mktemp)"
if cast logs --address "$PM" "RegisterPool(address)" --from-block 0 --to-block "$LATEST" --rpc-url "$RPC" >"$TMP" 2>/dev/null; then
  cat "$TMP"
else
  : > "$TMP"
  CHUNK=250000
  START=0
  while [ "$START" -le "$LATEST" ]; do
    END=$((START + CHUNK - 1))
    if [ "$END" -gt "$LATEST" ]; then END="$LATEST"; fi
    cast logs --address "$PM" "RegisterPool(address)" --from-block "$START" --to-block "$END" --rpc-url "$RPC" >>"$TMP" 2>/dev/null || true
    START=$((END + 1))
  done
fi

echo "REGISTER_POOL_LOGS_BEGIN"
cat "$TMP"
echo "REGISTER_POOL_LOGS_END"

# Extract every 20-byte hex address from log output and probe those that actually behave like LongPool.
mapfile -t CANDIDATES < <(grep -Eo '0x[a-fA-F0-9]{40}' "$TMP" | sort -u)
for P in "${CANDIDATES[@]}"; do
  COLL="$(cast call "$P" "collateralToken()(address)" --rpc-url "$RPC" 2>/dev/null || true)"
  [ -n "$COLL" ] || continue
  echo "POOL=$P collateralToken=$COLL"
  echo "  fxUSD=$(cast call "$P" "fxUSD()(address)" --rpc-url "$RPC" 2>/dev/null || true)"
  echo "  poolManager=$(cast call "$P" "poolManager()(address)" --rpc-url "$RPC" 2>/dev/null || true)"
  echo "  configuration=$(cast call "$P" "configuration()(address)" --rpc-url "$RPC" 2>/dev/null || true)"
  echo "  priceOracle=$(cast call "$P" "priceOracle()(address)" --rpc-url "$RPC" 2>/dev/null || true)"
  echo "  debtRatioRange=$(cast call "$P" "getDebtRatioRange()(uint256,uint256)" --rpc-url "$RPC" 2>/dev/null || true)"
  echo "  rebalanceRatios=$(cast call "$P" "getRebalanceRatios()(uint256,uint256)" --rpc-url "$RPC" 2>/dev/null || true)"
  echo "  liquidateRatios=$(cast call "$P" "getLiquidateRatios()(uint256,uint256)" --rpc-url "$RPC" 2>/dev/null || true)"
  echo "  nextPositionId=$(cast call "$P" "getNextPositionId()(uint32)" --rpc-url "$RPC" 2>/dev/null || true)"
  echo "  borrowPaused=$(cast call "$P" "isBorrowPaused()(bool)" --rpc-url "$RPC" 2>/dev/null || true)"
  echo "  redeemPaused=$(cast call "$P" "isRedeemPaused()(bool)" --rpc-url "$RPC" 2>/dev/null || true)"
  if [ "$(echo "$COLL" | tr '[:upper:]' '[:lower:]')" = "$(echo "$VBWBTC" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "MATCHED_VBWBTC_POOL=$P"
  fi
done
