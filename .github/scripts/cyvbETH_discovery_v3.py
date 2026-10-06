#!/usr/bin/env python3
# cyvbETH live-topology discovery v3. Temporary branch-only diagnostic.
import json, os, subprocess

RPC = "https://rpc.katana.network/"
POOL_MANAGER = "0x27b3eE81DF2Dd7356D5ac282e2416991A616f96a"
VBETH = "0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62"
VBUSDC = "0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36"
SUSHI_FACTORY = "0x203e8740894c8955cB8950759876d7E7E45E04c1"
MORPHO = "0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc"
MORPHO_MARKET = "0x2c4f26c76b4de51d3c9260c15a796cd2a35efab17786d0aa78ca2e638b0f8ba8"

def sh(*args):
    return subprocess.check_output(list(args), text=True).strip()

def cast(*args):
    return sh("cast", *args, "--rpc-url", RPC)

def rpc(method, *params):
    out = sh("cast", "rpc", method, *params, "--rpc-url", RPC)
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return out.strip().strip('"')

def main():
    latest_hex = rpc("eth_blockNumber")
    latest = int(latest_hex, 16)
    lo, hi = 0, latest
    while lo < hi:
        mid = (lo + hi) // 2
        code = cast("code", POOL_MANAGER, "--block", str(mid))
        if code != "0x":
            hi = mid
        else:
            lo = mid + 1
    creation = lo
    topic0 = sh("cast", "keccak", "RegisterPool(address)").lower()

    pools = []
    step = 100_000
    for start in range(creation, latest + 1, step):
        end = min(start + step - 1, latest)
        filt = json.dumps({
            "address": POOL_MANAGER,
            "fromBlock": hex(start),
            "toBlock": hex(end),
            "topics": [topic0],
        }, separators=(",", ":"))
        logs = rpc("eth_getLogs", filt)
        if isinstance(logs, str):
            logs = json.loads(logs)
        for log in logs:
            if len(log.get("topics", [])) > 1:
                pool = "0x" + log["topics"][1][-40:]
                if pool.lower() not in {x.lower() for x in pools}:
                    pools.append(pool)

    rows = [
        f"chain_id={cast('chain-id')}",
        f"latest_block={latest}",
        f"pool_manager_creation_block={creation}",
        f"vbeth_symbol={cast('call', VBETH, 'symbol()(string)')}",
        f"vbeth_decimals={cast('call', VBETH, 'decimals()(uint8)')}",
        f"registered_pool_count={len(pools)}",
    ]
    for pool in pools:
        rows.append(f"POOL={pool}")
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
            rows.append(f" {label}={value}")

    for fee in (100, 500, 3000, 10000):
        rows.append(
            f"sushi_vbusdc_vbeth_fee_{fee}="
            + cast("call", SUSHI_FACTORY, "getPool(address,address,uint24)(address)", VBUSDC, VBETH, str(fee))
        )

    rows.append(f"morpho_code_prefix={cast('code', MORPHO)[:18]}")
    rows.append(
        "morpho_market_params="
        + cast(
            "call", MORPHO,
            "idToMarketParams(bytes32)(address,address,address,address,uint256)",
            MORPHO_MARKET,
        ).replace("\n", ",")
    )

    text = "\n".join(rows) + "\n"
    print(text, end="")
    target = os.environ.get("DISCOVERY_OUT")
    if target:
        with open(target, "w", encoding="utf-8") as f:
            f.write(text)

if __name__ == "__main__":
    main()
