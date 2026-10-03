#!/usr/bin/env bash
set -euo pipefail
RPC="${KATANA_RPC_URL:-https://katana.drpc.org/}"
FACTORY=0x203e8740894c8955cB8950759876d7E7E45E04c1
VBUSDC=0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36
VBWBTC=0x0913DA6Da4b42f538B445599b46Bb4622342Cf52
ROUTER=0x01F9894f92ea9224fECc8C35482E20a05De13582
for fee in 100 500 3000 10000; do
  echo "pool fee=$fee => $(cast call "$FACTORY" "getPool(address,address,uint24)(address)" "$VBUSDC" "$VBWBTC" "$fee" --rpc-url "$RPC")"
done
echo "router vbUSDC->vbWBTC => $(cast call "$ROUTER" "routeFor(address,address)(bytes)" "$VBUSDC" "$VBWBTC" --rpc-url "$RPC")"
