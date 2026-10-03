#!/usr/bin/env bash
set -euo pipefail

RPC="${KATANA_RPC_URL:-https://katana.drpc.org/}"
PM="0xFae375C9eA6636c40deB92DD91B7dbbF51BD3C68"
VBWBTC="0x0913DA6Da4b42f538B445599b46Bb4622342Cf52"
FXBASE="0x6cf6757725886716Bc3c6A4bB93d02F1d1E3e7Dd"
CONFIG="0xB582Eb17059171D09B4F78f0BB63E47C7ceEfF62"
POOL_ARRAY_SLOT=150

RAW_LEN="$(cast storage "$PM" "$POOL_ARRAY_SLOT" --rpc-url "$RPC")"
LEN="$(python3 -c "print(int('$RAW_LEN',16))")"
PADDED="$(python3 -c "print('0x'+format($POOL_ARRAY_SLOT,'064x'))")"
BASE="$(cast keccak "$PADDED")"

echo "poolManager=$PM"
echo "pools_slot=$POOL_ARRAY_SLOT"
echo "pools_length=$LEN"
echo "pools_array_base=$BASE"

echo "fxBASE stableToken=$(cast call "$FXBASE" "stableToken()(address)" --rpc-url "$RPC")"
echo "fxBASE yieldToken=$(cast call "$FXBASE" "yieldToken()(address)" --rpc-url "$RPC")"
echo "fxBASE stablePrice=$(cast call "$FXBASE" "getStableTokenPrice()(uint256)" --rpc-url "$RPC")"
echo "fxBASE stablePriceWithScale=$(cast call "$FXBASE" "getStableTokenPriceWithScale()(uint256)" --rpc-url "$RPC")"
echo "config borrowAllowed=$(cast call "$CONFIG" "isBorrowAllowed()(bool)" --rpc-url "$RPC")"
echo "config redeemAllowed=$(cast call "$CONFIG" "isRedeemAllowed()(bool)" --rpc-url "$RPC")"
echo "config stableRepayAllowed=$(cast call "$CONFIG" "isStableRepayAllowed()(bool)" --rpc-url "$RPC")"
echo "config fundingEnabled=$(cast call "$CONFIG" "isFundingEnabled()(bool)" --rpc-url "$RPC")"

for ((i=0;i<LEN;i++)); do
  SLOT="$(python3 -c "print(hex(int('$BASE',16)+$i))")"
  RAW="$(cast storage "$PM" "$SLOT" --rpc-url "$RPC")"
  P="0x${RAW:26:40}"
  COLL="$(cast call "$P" "collateralToken()(address)" --rpc-url "$RPC")"
  echo "pool[$i]=$P collateral=$COLL"

  if [ "$(echo "$COLL" | tr '[:upper:]' '[:lower:]')" = "$(echo "$VBWBTC" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "MATCHED_VBWBTC_POOL=$P"
    ORACLE="$(cast call "$P" "priceOracle()(address)" --rpc-url "$RPC")"
    PCONFIG="$(cast call "$P" "configuration()(address)" --rpc-url "$RPC")"
    echo "fxUSD=$(cast call "$P" "fxUSD()(address)" --rpc-url "$RPC")"
    echo "poolManager=$(cast call "$P" "poolManager()(address)" --rpc-url "$RPC")"
    echo "configuration=$PCONFIG"
    echo "priceOracle=$ORACLE"
    echo "oraclePrice=$(cast call "$ORACLE" "getPrice()(uint256,uint256,uint256)" --rpc-url "$RPC")"
    echo "nextPositionId=$(cast call "$P" "getNextPositionId()(uint32)" --rpc-url "$RPC")"
    echo "debtRatioRange=$(cast call "$P" "getDebtRatioRange()(uint256,uint256)" --rpc-url "$RPC")"
    echo "rebalanceRatios=$(cast call "$P" "getRebalanceRatios()(uint256,uint256)" --rpc-url "$RPC")"
    echo "liquidateRatios=$(cast call "$P" "getLiquidateRatios()(uint256,uint256)" --rpc-url "$RPC")"
    echo "borrowPaused=$(cast call "$P" "isBorrowPaused()(bool)" --rpc-url "$RPC")"
    echo "redeemPaused=$(cast call "$P" "isRedeemPaused()(bool)" --rpc-url "$RPC")"
    echo "poolInfo=$(cast call "$PM" "getPoolInfo(address)(uint256,uint256,uint256,uint256,uint256)" "$P" --rpc-url "$RPC")"
    echo "poolFeeRatio_zero=$(cast call "$PCONFIG" "getPoolFeeRatio(address,address)(uint256,uint256,uint256,uint256)" "$P" "0x0000000000000000000000000000000000000000" --rpc-url "$RPC" 2>/dev/null || true)"
  fi
done
