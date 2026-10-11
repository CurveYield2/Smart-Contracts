// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {FuseAction} from "../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

interface IVaultExecW {
    function execute(FuseAction[] calldata calls) external;
}

/// Withdraws lent avKAT from Morpho 0x5c60 back to the live vault (IPOR MorphoSupplyFuse exit).
/// WITHDRAW_AVKAT (env, whole avKAT; 0 or unset = everything). Limited by the market's available liquidity.
///
///   forge script script/L3_WithdrawLend.s.sol --root <phase2 path> --rpc-url katana   (add --broadcast ...)
contract L3_WithdrawLend is Phase2Base {
    using MorphoBalancesLib for IMorpho;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        address supplyFuse = vm.parseJsonAddress(
            vm.readFile(_lendingPath()), ".lendSupplyFuse"
        );
        IMorpho morpho = IMorpho(MORPHO);
        MarketParams memory p = morpho.idToMarketParams(Id.wrap(LEND_MARKET));
        uint256 lent = morpho.expectedSupplyAssets(p, VAULT);
        (uint256 supply,, uint256 borrow,) = morpho.expectedMarketBalances(p);
        uint256 available = supply > borrow ? supply - borrow : 0;
        uint256 wanted = vm.envOr("WITHDRAW_AVKAT", uint256(0)) * 1e18;
        uint256 amount = wanted == 0 || wanted > lent ? lent : wanted;
        if (amount > available) amount = available;
        console2.log("lent / market available / withdrawing:", lent, available, amount);
        require(amount > 0, "nothing withdrawable");
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(supplyFuse, abi.encodeWithSignature("exit((bytes32,uint256))", LEND_MARKET, amount));
        _start();
        IVaultExecW(VAULT).execute(a);
        _stop();
        console2.log("after: lent", morpho.expectedSupplyAssets(p, VAULT));
    }
}
