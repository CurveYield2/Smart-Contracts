#!/usr/bin/env bash
set -euo pipefail

RPC="${KATANA_RPC_URL:-https://katana.drpc.org/}"
FXUSD="0x1364b238C668A2dec1294174e4798E8c09979f86"
VBWBTC="0x0913DA6Da4b42f538B445599b46Bb4622342Cf52"
PM="$(cast call "$FXUSD" "poolManager()(address)" --rpc-url "$RPC")"

echo "poolManager=$PM"
echo "Scanning PoolManager linear storage for small dynamic-array lengths..."

for SLOT in $(seq 80 145); do
  RAW="$(cast storage "$PM" "$SLOT" --rpc-url "$RPC" 2>/dev/null || true)"
  [ -n "$RAW" ] || continue
  DEC="$(python3 -c "print(int('$RAW',16))")"
  if [ "$DEC" -ge 1 ] && [ "$DEC" -le 20 ]; then
    echo "candidate_slot=$SLOT raw=$RAW decimal=$DEC"
    PADDED="$(python3 -c "print('0x'+format($SLOT,'064x'))")"
    BASE="$(cast keccak "$PADDED")"
    echo "  array_base=$BASE"
    VALID=0
    for ((i=0;i<DEC;i++)); do
      ESLOT="$(python3 -c "print(hex(int('$BASE',16)+$i))")"
      ERAW="$(cast storage "$PM" "$ESLOT" --rpc-url "$RPC" 2>/dev/null || true)"
      [ -n "$ERAW" ] || continue
      ADDR="0x${ERAW:26:40}"
      CODE="$(cast code "$ADDR" --rpc-url "$RPC" 2>/dev/null || true)"
      if [ -n "$CODE" ] && [ "$CODE" != "0x" ]; then
        COLL="$(cast call "$ADDR" "collateralToken()(address)" --rpc-url "$RPC" 2>/dev/null || true)"
        if [ -n "$COLL" ]; then
          VALID=$((VALID+1))
          echo "  pool[$i]=$ADDR collateralToken=$COLL"
          echo "    fxUSD=$(cast call "$ADDR" "fxUSD()(address)" --rpc-url "$RPC" 2>/dev/null || true)"
          echo "    poolManager=$(cast call "$ADDR" "poolManager()(address)" --rpc-url "$RPC" 2>/dev/null || true)"
          echo "    configuration=$(cast call "$ADDR" "configuration()(address)" --rpc-url "$RPC" 2>/dev/null || true)"
          echo "    priceOracle=$(cast call "$ADDR" "priceOracle()(address)" --rpc-url "$RPC" 2>/dev/null || true)"
          echo "    debtRatioRange=$(cast call "$ADDR" "getDebtRatioRange()(uint256,uint256)" --rpc-url "$RPC" 2>/dev/null || true)"
          echo "    rebalanceRatios=$(cast call "$ADDR" "getRebalanceRatios()(uint256,uint256)" --rpc-url "$RPC" 2>/dev/null || true)"
          echo "    liquidateRatios=$(cast call "$ADDR" "getLiquidateRatios()(uint256,uint256)" --rpc-url "$RPC" 2>/dev/null || true)"
          echo "    nextPositionId=$(cast call "$ADDR" "getNextPositionId()(uint32)" --rpc-url "$RPC" 2>/dev/null || true)"
          echo "    borrowPaused=$(cast call "$ADDR" "isBorrowPaused()(bool)" --rpc-url "$RPC" 2>/dev/null || true)"
          echo "    redeemPaused=$(cast call "$ADDR" "isRedeemPaused()(bool)" --rpc-url "$RPC" 2>/dev/null || true)"
          echo "    price=$(ORACLE=$(cast call "$ADDR" "priceOracle()(address)" --rpc-url "$RPC" 2>/dev/null || true); [ -n "$ORACLE" ] && cast call "$ORACLE" "getPrice()(uint256,uint256,uint256)" --rpc-url "$RPC" 2>/dev/null || true)"
          echo "    poolInfo=$(cast call "$PM" "getPoolInfo(address)(uint256,uint256,uint256,uint256,uint256)" "$ADDR" --rpc-url "$RPC" 2>/dev/null || true)"
          if [ "$(echo "$COLL" | tr '[:upper:]' '[:lower:]')" = "$(echo "$VBWBTC" | tr '[:upper:]' '[:lower:]')" ]; then
            echo "MATCHED_VBWBTC_POOL=$ADDR"
          fi
        fi
      fi
    done
    echo "  valid_long_pools=$VALID"
  fi
done
