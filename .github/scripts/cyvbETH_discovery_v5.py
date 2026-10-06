#!/usr/bin/env python3
# cyvbETH Sushi/CurveYield-router route discovery v5.
# GitHub Actions only; no persistent repository output.

import os
import subprocess

RPC = "https://rpc.katana.network/"
ROUTER = "0x01F9894f92ea9224fECc8C35482E20a05De13582"
FACTORY = "0x203e8740894c8955cB8950759876d7E7E45E04c1"
VBETH = "0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62"
WEETH = "0x9893989433e7a383Cb313953e4c2365107dc19a7"
VBUSDC = "0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36"
ZERO = "0x0000000000000000000000000000000000000000"


def sh(*args):
    return subprocess.check_output(list(args), text=True).strip()


def cast(*args):
    return sh("cast", *args, "--rpc-url", RPC)


def try_call(address, signature, *args):
    try:
        return cast("call", address, signature, *args).replace("\n", ",")
    except subprocess.CalledProcessError:
        return "CALL_FAILED"


def route(a, b):
    return try_call(ROUTER, "routeFor(address,address)(bytes)", a, b)


def inspect_pair(label, a, b):
    rows = [f"PAIR={label}"]
    for fee in (100, 500, 3000, 10000):
        pool = try_call(FACTORY, "getPool(address,address,uint24)(address)", a, b, str(fee))
        rows.append(f" fee_{fee}_pool={pool}")
        if pool.lower() != ZERO:
            rows.append(f" fee_{fee}_liquidity={try_call(pool, 'liquidity()(uint128)')}")
            rows.append(f" fee_{fee}_a_balance={try_call(a, 'balanceOf(address)(uint256)', pool)}")
            rows.append(f" fee_{fee}_b_balance={try_call(b, 'balanceOf(address)(uint256)', pool)}")
            rows.append(f" fee_{fee}_slot0={try_call(pool, 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)')}")
    return rows


def main():
    rows = [
        f"chain_id={cast('chain-id')}",
        f"router_owner={try_call(ROUTER, 'owner()(address)')}",
        f"route_vbeth_weeth={route(VBETH, WEETH)}",
        f"route_weeth_vbeth={route(WEETH, VBETH)}",
        f"route_vbusdc_vbeth={route(VBUSDC, VBETH)}",
        f"route_vbeth_vbusdc={route(VBETH, VBUSDC)}",
    ]
    rows += inspect_pair("vbETH/weETH", VBETH, WEETH)
    rows += inspect_pair("vbUSDC/vbETH", VBUSDC, VBETH)
    text = "\n".join(rows) + "\n"
    print(text, end="")
    target = os.environ.get("DISCOVERY_OUT")
    if target:
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(text)


if __name__ == "__main__":
    main()
