#!/usr/bin/env python3
# cyvbETH live-topology discovery v2. Temporary branch-only diagnostic.

import json
import os
import subprocess
import sys
import urllib.request

RPC = "https://rpc.katana.network/"
POOL_MANAGER = "0x27b3eE81DF2Dd7356D5ac282e2416991A616f96a"
VBETH = "0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62"
VBUSDC = "0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36"
SUSHI_FACTORY = "0x203e8740894c8955cB8950759876d7E7E45E04c1"
MORPHO = "0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc"
MORPHO_MARKET = "0x2c4f26c76b4de51d3c9260c15a796cd2a35efab17786d0aa78ca2e638b0f8ba8"


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as response:
        data = json.load(response)
    if "error" in data:
        raise RuntimeError(data["error"])
    return data["result"]


def cast(*args):
    return subprocess.check_output(["cast", *args, "--rpc-url", RPC], text=True).strip()


def main():
    latest = int(rpc("eth_blockNumber", []), 16)
    lo, hi = 0, latest
    while lo < hi:
        mid = (lo + hi) // 2
        if rpc("eth_getCode", [POOL_MANAGER.lower(), hex(mid)]) != "0x":
            hi = mid
        else:
            lo = mid + 1
    creation_block = lo
    topic0 = subprocess.check_output(["cast", "keccak", "RegisterPool(address)"], text=True).strip().lower()

    pools = []
    step = 100_000
    for start in range(creation_block, latest + 1, step):
        end = min(start + step - 1, latest)
        logs = rpc(
            "eth_getLogs",
            [{
                "address": POOL_MANAGER.lower(),
                "fromBlock": hex(start),
                "toBlock": hex(end),
                "topics": [topic0],
            }],
        )
        for log in logs:
            if len(log["topics"]) > 1:
                pool = "0x" + log["topics"][1][-40:]
                if pool.lower() not in {x.lower() for x in pools}:
                    pools.append(pool)

    out = []
    out.append(f"chain_id={cast('chain-id')}")
    out.append(f"latest_block={latest}")
    out.append(f"pool_manager_creation_block={creation_block}")
    out.append(f"vbeth_symbol={cast('call', VBETH, 'symbol()(string)')}")
    out.append(f"vbeth_decimals={cast('call', VBETH, 'decimals()(uint8)')}")
    out.append(f"registered_pool_count={len(pools)}")

    for pool in pools:
        out.append(f"POOL={pool}")
        for label, sig in [
            ("collateral", "collateralToken()(address)"),
            ("fxusd", "fxUSD()(address)"),
            ("manager", "poolManager()(address)"),
            ("oracle", "priceOracle()(address)"),
            ("config", "configuration()(address)"),
            ("debt_range", "getDebtRatioRange()(uint256,uint256)"),
        ]:
            try:
                value = cast("call", pool, sig).replace("\n", ",")
            except subprocess.CalledProcessError:
                value = "CALL_FAILED"
            out.append(f" {label}={value}")

    for fee in (100, 500, 3000, 10000):
        pool = cast(
            "call",
            SUSHI_FACTORY,
            "getPool(address,address,uint24)(address)",
            VBUSDC,
            VBETH,
            str(fee),
        )
        out.append(f"sushi_vbusdc_vbeth_fee_{fee}={pool}")

    out.append(f"morpho_code_prefix={cast('code', MORPHO)[:18]}")
    params = cast(
        "call",
        MORPHO,
        "idToMarketParams(bytes32)(address,address,address,address,uint256)",
        MORPHO_MARKET,
    ).replace("\n", ",")
    out.append(f"morpho_market_params={params}")

    text = "\n".join(out) + "\n"
    print(text, end="")
    target = os.environ.get("DISCOVERY_OUT")
    if target:
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(text)


if __name__ == "__main__":
    main()
