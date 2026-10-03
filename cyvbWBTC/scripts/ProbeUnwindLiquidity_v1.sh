#!/usr/bin/env bash
set -euo pipefail
RPC="${KATANA_RPC_URL:-https://katana.drpc.org/}"
POOLS="100:0x92C97b702b5f8DfEa8B87535d63f7Dbe8E40E3E8 500:0x744676B3CeD942D78F9b8e9cd22246Db5c32395c 3000:0x4488005Fd5EEa2E22a80cb2A0e820ED6066e687F"
for x in $POOLS; do
  fee="${x%%:*}"; p="${x#*:}"
  echo "fee=$fee pool=$p"
  echo " token0=$(cast call "$p" "token0()(address)" --rpc-url "$RPC")"
  echo " token1=$(cast call "$p" "token1()(address)" --rpc-url "$RPC")"
  echo " liquidity=$(cast call "$p" "liquidity()(uint128)" --rpc-url "$RPC")"
  echo " slot0=$(cast call "$p" "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" --rpc-url "$RPC")"
done
