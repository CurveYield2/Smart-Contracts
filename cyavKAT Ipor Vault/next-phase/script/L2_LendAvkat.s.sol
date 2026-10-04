// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {FuseAction} from "../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

interface IV1MorphoFuse {
    function totalManagedAvkat() external view returns (uint256);
    function reserveAllocationBps() external view returns (uint16);
}

interface IVaultExecL {
    function execute(FuseAction[] calldata calls) external;
}

interface IErc20L {
    function balanceOf(address) external view returns (uint256);
}

/// Lends avKAT from the live v1 vault into Morpho market 0x5c60 (IPOR MorphoSupplyFuse, installed by L1).
/// LEND_AVKAT (env, whole avKAT; 0 or unset = the maximum allowed). The amount is capped by all of:
///   1. v1 safety: the v1 Morpho fuse reverts deployAssets if idle < reserve + reward, and it does not count lent avKAT
///      -> lend at most (idle - managed * reserveBps - 3 reward) / (1 - reserveBps)
///   2. 20% cap of managed avKAT (managed + already lent)
///   3. ownership rule: <= 20% of the market's supply, except the vault's first 10,000 avKAT
///
///   LEND_AVKAT=500 forge script script/L2_LendAvkat.s.sol --root <phase2 path> --rpc-url katana   (add --broadcast ...)
contract L2_LendAvkat is Phase2Base {
    using MorphoBalancesLib for IMorpho;

    address internal constant V1_MORPHO_FUSE = 0x79E88DD967Ef9a31046455dB94b1e487329Ed705;
    uint256 internal constant REWARD_RESERVE = 3e18;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        address supplyFuse = vm.parseJsonAddress(
            vm.readFile(_lendingPath()), ".lendSupplyFuse"
        );
        (uint256 maxAllowed, uint256 lent, uint256 marketSupply) = maxLendable();
        uint256 wanted = vm.envOr("LEND_AVKAT", uint256(0)) * 1e18;
        uint256 amount = wanted == 0 || wanted > maxAllowed ? maxAllowed : wanted;
        console2.log("already lent / market supply:", lent, marketSupply);
        console2.log("max allowed now / lending:  ", maxAllowed, amount);
        require(amount > 0, "nothing lendable under the v1 / cap / ownership limits");

        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(supplyFuse, abi.encodeWithSignature("enter((bytes32,uint256))", LEND_MARKET, amount));
        _start();
        IVaultExecL(VAULT).execute(a);
        _stop();
        (, uint256 lentAfter, uint256 supplyAfter) = maxLendable();
        console2.log("after: lent / market supply:", lentAfter, supplyAfter);
    }

    function maxLendable() public view returns (uint256 max_, uint256 lent_, uint256 marketSupply_) {
        IMorpho morpho = IMorpho(MORPHO);
        MarketParams memory p = morpho.idToMarketParams(Id.wrap(LEND_MARKET));
        lent_ = morpho.expectedSupplyAssets(p, VAULT);
        (marketSupply_,,,) = morpho.expectedMarketBalances(p);
        uint256 idle = IErc20L(AVKAT).balanceOf(VAULT);
        uint256 managed = IV1MorphoFuse(V1_MORPHO_FUSE).totalManagedAvkat(); // excludes lent avKAT
        uint256 r = IV1MorphoFuse(V1_MORPHO_FUSE).reserveAllocationBps();
        // 1. v1 safety
        uint256 floor = managed * r / 10_000 + REWARD_RESERVE;
        max_ = idle > floor ? (idle - floor) * 10_000 / (10_000 - r) : 0;
        // 2. 20% cap of everything managed, lent included
        uint256 cap = (managed + lent_) * 2_000 / 10_000;
        uint256 capRoom = cap > lent_ ? cap - lent_ : 0;
        if (capRoom < max_) max_ = capRoom;
        // 3. ownership: (v + x) / (T + x) <= 20%, except the first 10,000 avKAT
        uint256 lhs = marketSupply_ * 2_000;
        uint256 rhs = lent_ * 10_000;
        uint256 ownRoom = lhs > rhs ? (lhs - rhs) / 8_000 : 0;
        uint256 exemptRoom = lent_ < 10_000e18 ? 10_000e18 - lent_ : 0;
        if (exemptRoom > ownRoom) ownRoom = exemptRoom;
        if (ownRoom < max_) max_ = ownRoom;
    }
}
