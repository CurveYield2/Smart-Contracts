#!/usr/bin/env python3
"""Read-only Katana/IPOR probe for the cyvbUSDC deployment.

v1 intentionally performs no transactions. It reads the live IPOR factory and
reference CurveYield vault so deployment code can clone exact configuration
without relying on explorer labels.
"""

import json
import os
from web3 import Web3

RPC = os.environ.get("KATANA_RPC_URL", "https://rpc.katana.network/")
FACTORY = Web3.to_checksum_address("0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B")
REFERENCE_VAULT = Web3.to_checksum_address("0xEd83daf48429cfb2C650Fd721b9241e180fd4548")
KAT = Web3.to_checksum_address("0x7f1f4b4b29f5058fa32cc7a97141b8d7e5abdc2d")
VB_USDC = Web3.to_checksum_address("0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36")\nREFERENCE_REWARD_ROUTER = Web3.to_checksum_address("0x346f02528aD59D1B57315b6d67FD6a43559a87Bb")

FACTORY_ABI = [
    {
        "type": "function",
        "name": "getDaoFeePackages",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{
            "name": "",
            "type": "tuple[]",
            "components": [
                {"name": "managementFee", "type": "uint256"},
                {"name": "performanceFee", "type": "uint256"},
                {"name": "feeRecipient", "type": "address"},
            ],
        }],
    },
]

VAULT_ABI = [
    {"type": "function", "name": "name", "stateMutability": "view", "inputs": [], "outputs": [{"type": "string"}]},
    {"type": "function", "name": "symbol", "stateMutability": "view", "inputs": [], "outputs": [{"type": "string"}]},
    {"type": "function", "name": "asset", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
    {"type": "function", "name": "getFuses", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address[]"}]},
    {"type": "function", "name": "getInstantWithdrawalFuses", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address[]"}]},
    {"type": "function", "name": "getAccessManagerAddress", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
    {"type": "function", "name": "getRewardsClaimManagerAddress", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
    {"type": "function", "name": "getPriceOracleMiddleware", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
    {
        "type": "function",
        "name": "getPerformanceFeeData",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"type": "tuple", "components": [
            {"name": "feeAccount", "type": "address"},
            {"name": "feeInPercentage", "type": "uint16"},
        ]}],
    },
    {
        "type": "function",
        "name": "getManagementFeeData",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"type": "tuple", "components": [
            {"name": "feeAccount", "type": "address"},
            {"name": "feeInPercentage", "type": "uint16"},
            {"name": "lastUpdateTimestamp", "type": "uint32"},
        ]}],
    },
    {
        "type": "function",
        "name": "getMarketSubstrates",
        "stateMutability": "view",
        "inputs": [{"name": "marketId_", "type": "uint256"}],
        "outputs": [{"type": "bytes32[]"}],
    },
    {
        "type": "function",
        "name": "getDependencyBalanceGraph",
        "stateMutability": "view",
        "inputs": [{"name": "marketId_", "type": "uint256"}],
        "outputs": [{"type": "uint256[]"}],
    },
]

REWARDS_ABI = [
    {"type": "function", "name": "getRewardsFuses", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address[]"}]},
]

PRICE_MANAGER_ABI = [
    {
        "type": "function",
        "name": "getSourceOfAssetPrice",
        "stateMutability": "view",
        "inputs": [{"name": "asset_", "type": "address"}],
        "outputs": [{"type": "address"}],
    },
]

REWARD_ROUTER_ABI = [\n    {\n        "type": "function",\n        "name": "routeFor",\n        "stateMutability": "view",\n        "inputs": [{"name": "tokenIn", "type": "address"}, {"name": "tokenOut", "type": "address"}],\n        "outputs": [{"type": "bytes"}],\n    },\n]\n\nCOMMON_FUSE_ABI = [
    {"type": "function", "name": "MARKET_ID", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "VERSION", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
    {"type": "function", "name": "EXECUTOR", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
    {"type": "function", "name": "DISTRIBUTOR", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
    {"type": "function", "name": "ROUTER", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
    {"type": "function", "name": "MORPHO", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
]

def try_call(contract, fn_name, *args):
    try:
        return getattr(contract.functions, fn_name)(*args).call()
    except Exception:
        return None

def as_jsonable(v):
    if isinstance(v, bytes):
        return "0x" + v.hex()
    if isinstance(v, tuple):
        return [as_jsonable(x) for x in v]
    if isinstance(v, list):
        return [as_jsonable(x) for x in v]
    return v

def inspect_fuse(w3, address):
    c = w3.eth.contract(address=Web3.to_checksum_address(address), abi=COMMON_FUSE_ABI)
    out = {"address": address}
    for name in ("MARKET_ID", "VERSION", "EXECUTOR", "DISTRIBUTOR", "ROUTER", "MORPHO"):
        value = try_call(c, name)
        if value is not None:
            out[name] = as_jsonable(value)
    return out

def main():
    w3 = Web3(Web3.HTTPProvider(RPC, request_kwargs={"timeout": 30}))
    if not w3.is_connected():
        raise SystemExit("Katana RPC connection failed")

    print(f"chain_id={w3.eth.chain_id}")
    print(f"block={w3.eth.block_number}")

    factory = w3.eth.contract(address=FACTORY, abi=FACTORY_ABI)
    packages = factory.functions.getDaoFeePackages().call()
    print("\nDAO_FEE_PACKAGES")
    for i, p in enumerate(packages):
        print(json.dumps({
            "index": i,
            "managementFeeBps": int(p[0]),
            "performanceFeeBps": int(p[1]),
            "feeRecipient": p[2],
        }, sort_keys=True))

    vault = w3.eth.contract(address=REFERENCE_VAULT, abi=VAULT_ABI)
    reference = {
        "name": vault.functions.name().call(),
        "symbol": vault.functions.symbol().call(),
        "asset": vault.functions.asset().call(),
        "accessManager": vault.functions.getAccessManagerAddress().call(),
        "rewardsManager": vault.functions.getRewardsClaimManagerAddress().call(),
        "priceManager": vault.functions.getPriceOracleMiddleware().call(),
        "performanceFeeData": as_jsonable(vault.functions.getPerformanceFeeData().call()),
        "managementFeeData": as_jsonable(vault.functions.getManagementFeeData().call()),
        "fuses": vault.functions.getFuses().call(),
        "instantWithdrawalFuses": vault.functions.getInstantWithdrawalFuses().call(),
    }
    print("\nREFERENCE_VAULT")
    print(json.dumps(reference, indent=2, sort_keys=True))

    print("\nREFERENCE_MARKETS")
    for market_id in (7, 12, 14, 41):
        substrates = vault.functions.getMarketSubstrates(market_id).call()
        deps = vault.functions.getDependencyBalanceGraph(market_id).call()
        print(json.dumps({
            "marketId": market_id,
            "substrates": as_jsonable(substrates),
            "dependencies": as_jsonable(deps),
        }, sort_keys=True))

    print("\nREFERENCE_FUSE_INTROSPECTION")
    for fuse in reference["fuses"]:
        print(json.dumps(inspect_fuse(w3, fuse), sort_keys=True))

    rewards_manager = w3.eth.contract(address=reference["rewardsManager"], abi=REWARDS_ABI)
    reward_fuses = rewards_manager.functions.getRewardsFuses().call()
    print("\nREFERENCE_REWARD_FUSES")
    for fuse in reward_fuses:
        print(json.dumps(inspect_fuse(w3, fuse), sort_keys=True))

    router = w3.eth.contract(address=REFERENCE_REWARD_ROUTER, abi=REWARD_ROUTER_ABI)\n    print("\\nREFERENCE_REWARD_ROUTER_ROUTES")\n    for token_name, token_out in (("vbUSDC", VB_USDC), ("referenceAsset", reference["asset"])):\n        route = router.functions.routeFor(KAT, token_out).call()\n        print(json.dumps({\n            "router": REFERENCE_REWARD_ROUTER,\n            "tokenIn": KAT,\n            "tokenOutName": token_name,\n            "tokenOut": token_out,\n            "routeBytes": "0x" + route.hex(),\n            "routeLength": len(route),\n        }, sort_keys=True))\n\n    price_manager = w3.eth.contract(address=reference["priceManager"], abi=PRICE_MANAGER_ABI)
    print("\nREFERENCE_PRICE_SOURCES")
    for token_name, token in (("KAT", KAT), ("vbUSDC", VB_USDC), ("referenceAsset", reference["asset"])):
        source = try_call(price_manager, "getSourceOfAssetPrice", token)
        print(json.dumps({"token": token_name, "address": token, "source": source}, sort_keys=True))

if __name__ == "__main__":
    main()