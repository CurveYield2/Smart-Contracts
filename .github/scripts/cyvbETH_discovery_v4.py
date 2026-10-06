#!/usr/bin/env python3
# cyvbETH live f(x) topology discovery v4.
# Checks both known Katana fxUSD deployments and discovers every registered pool
# from the PoolManager each fxUSD exposes. GitHub Actions only.

import json
import os
import subprocess

RPC = "https://rpc.katana.network/"
FXUSD_CANDIDATES = [
    "0x4c03ff0f44A55e7098a09016E02a01d3cdC2FDF9",
    "0x1364b238C668A2dec1294174e4798E8c09979f86",
]
VBETH = "0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62"


def sh(*args):
    return subprocess.check_output(list(args), text=True).strip()


def cast(*args):
    return sh("cast", *args, "--rpc-url", RPC)


def rpc(method, *params):
    raw = sh("cast", "rpc", method, *params, "--rpc-url", RPC)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw.strip().strip('"')


def creation_block(address, latest):
    lo, hi = 0, latest
    while lo < hi:
        mid = (lo + hi) // 2
        if cast("code", address, "--block", str(mid)) != "0x":
            hi = mid
        else:
            lo = mid + 1
    return lo


def registered_pools(manager, latest):
    start = creation_block(manager, latest)
    topic0 = sh("cast", "keccak", "RegisterPool(address)").lower()
    pools = []
    for lo in range(start, latest + 1, 100_000):
        hi = min(lo + 99_999, latest)
        filt = json.dumps(
            {
                "address": manager,
                "fromBlock": hex(lo),
                "toBlock": hex(hi),
                "topics": [topic0],
            },
            separators=(",", ":"),
        )
        logs = rpc("eth_getLogs", filt)
        if isinstance(logs, str):
            logs = json.loads(logs)
        for log in logs:
            if len(log.get("topics", [])) > 1:
                pool = "0x" + log["topics"][1][-40:]
                if pool.lower() not in {p.lower() for p in pools}:
                    pools.append(pool)
    return start, pools


def try_call(address, signature, *args):
    try:
        return cast("call", address, signature, *args).replace("\n", ",")
    except subprocess.CalledProcessError:
        return "CALL_FAILED"


def main():
    latest = int(rpc("eth_blockNumber"), 16)
    rows = [
        f"chain_id={cast('chain-id')}",
        f"latest_block={latest}",
        f"vbeth={VBETH}",
        f"vbeth_symbol={try_call(VBETH, 'symbol()(string)')}",
        f"vbeth_decimals={try_call(VBETH, 'decimals()(uint8)')}",
    ]

    for fxusd in FXUSD_CANDIDATES:
        rows.append(f"FXUSD={fxusd}")
        manager = try_call(fxusd, "poolManager()(address)")
        rows.append(f" pool_manager={manager}")
        rows.append(f" get_markets={try_call(fxusd, 'getMarkets()(address[])')}")
        if manager == "CALL_FAILED" or not manager.startswith("0x"):
            continue
        start, pools = registered_pools(manager, latest)
        rows.append(f" manager_creation_block={start}")
        rows.append(f" registered_pool_count={len(pools)}")
        for pool in pools:
            rows.append(f" POOL={pool}")
            rows.append(f"  collateral={try_call(pool, 'collateralToken()(address)')}")
            rows.append(f"  fxusd={try_call(pool, 'fxUSD()(address)')}")
            rows.append(f"  manager={try_call(pool, 'poolManager()(address)')}")
            rows.append(f"  oracle={try_call(pool, 'priceOracle()(address)')}")
            rows.append(f"  config={try_call(pool, 'configuration()(address)')}")
            rows.append(f"  debt_range={try_call(pool, 'getDebtRatioRange()(uint256,uint256)')}")

    text = "\n".join(rows) + "\n"
    print(text, end="")
    target = os.environ.get("DISCOVERY_OUT")
    if target:
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(text)


if __name__ == "__main__":
    main()
