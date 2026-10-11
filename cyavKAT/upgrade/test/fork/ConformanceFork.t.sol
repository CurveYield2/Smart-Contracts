// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FuseAction} from "../../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {Phase2ForkBase, IErcFork, IExecFork, IGateFork} from "../helpers/Phase2ForkBase.sol";
import {CurveYieldBundleGuardFuse, CurveYieldBundleGuardFuseEnterData, CurveYieldBundleGuardFuseExitData} from "../../src/generic/CurveYieldBundleGuardFuse.sol";
import {CurveYieldErc20TransferFuse, CurveYieldErc20TransferFuseEnterData} from "../../src/generic/CurveYieldErc20TransferFuse.sol";
import {CurveYieldConfigKeys as K} from "../../src/governance/CurveYieldGateConfig.sol";

interface IVaultConf {
    function getFuses() external view returns (address[] memory);
    function isFuseSupported(address) external view returns (bool);
    function getInstantWithdrawalFuses() external view returns (address[] memory);
    function getMarketSubstrates(uint256) external view returns (bytes32[] memory);
    function getDependencyBalanceGraph(uint256) external view returns (uint256[] memory);
    function getActiveMarketsInBalanceFuses() external view returns (uint256[] memory);
    function totalAssetsInMarket(uint256) external view returns (uint256);
    function isBalanceFuseSupported(uint256, address) external view returns (bool);
}

interface IRcmConf {
    function isRewardFuseSupported(address) external view returns (bool);
}

interface IGateSub {
    function previewSubstrates(uint256) external view returns (bytes32[] memory);
}

/// @notice Fork suite of IPOR_FUSE_CONFORMANCE_SPEC Part 8: builds the new stack on a Katana fork with the REAL scripts
/// P0_00, P2_01 .. P2_04 and checks the removals, the market map, and the executor-driven flows.
contract ConformanceForkTest is Phase2ForkBase {
    IVaultConf internal v = IVaultConf(VAULT);

    uint256 internal constant ZERO_MARKET = type(uint256).max;

    function setUp() public {
        _setUpFork("conf");
    }

    function _contains(address[] memory a_, address x_) internal pure returns (bool) {
        for (uint256 i; i < a_.length; ++i) if (a_[i] == x_) return true;
        return false;
    }

    function _has(bytes32[] memory a_, bytes32 x_) internal pure returns (bool) {
        for (uint256 i; i < a_.length; ++i) if (a_[i] == x_) return true;
        return false;
    }

    // ---------------------------------------------------------------- removals (Part 2) and the market map (§4.4)

    function scenario_removalsAndMarketMap() external {
        address[] memory fuses = v.getFuses();
        // nothing from Part 2 is installed any more
        address[8] memory gone = [
            0x44D368e85f419C59aC01b7270D234d8BF19Df36e, 0x79E88DD967Ef9a31046455dB94b1e487329Ed705,
            0x987C05943855B22552898F032c1AEa7930E340da, 0xC66c3F5cC5e1550A0Ff960c06D630A2FBB80E19d,
            0x1f657229ec2D261be7dCD63ca82abed334d1f28b, 0x70a2f848E21c912D660FE2263E5Be538268A41Ec,
            0x1fB8b83bAf40c90F0b450A3fd7A8b2E97Ab2a3Ff, 0x84927bFf2a35a543ed94A7d96D5ccd162a167947
        ];
        for (uint256 i; i < gone.length; ++i) require(!_contains(fuses, gone[i]), "a removed fuse is still installed");
        // instant list: official fuses that pay avKAT only (B3)
        address[] memory instant = v.getInstantWithdrawalFuses();
        require(instant.length == 1 && instant[0] == _p2("lendSupplyFuse"), "instant list");
        // the reward fuses of the rewards claim manager are gone (D11)
        IRcmConf rcm = IRcmConf(RCM);
        require(!rcm.isRewardFuseSupported(0xc6d024E53204CADa27a3c60C77dA4de2e7eb5166), "Merkl claim fuse");
        require(!rcm.isRewardFuseSupported(0x8c82b1ba53784F888Ea49463e2138cDF82973470), "sweep fuse");
        require(!rcm.isRewardFuseSupported(0xb62241b19995Dac16D5905050804e1f06caC9704), "auto-harvest fuse");
        // market 54 is retired, the vKAT adapter is out of market 7 (F13), vbUSDC is in
        uint256[] memory active = v.getActiveMarketsInBalanceFuses();
        for (uint256 i; i < active.length; ++i) require(active[i] != 54, "market 54 active");
        bytes32[] memory m7 = v.getMarketSubstrates(7);
        require(!_has(m7, bytes32(uint256(uint160(0xD3d3fd4fe4c09d9BB826A37D368Cf8033e512507)))), "adapter in market 7");
        require(_has(m7, bytes32(uint256(uint160(0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36)))), "vbUSDC not in market 7");
        for (uint256 i; i < m7.length; ++i) require(uint256(m7[i]) >> 248 == 0, "typed substrate in market 7");
        // market 14: the loop and the USDC market; 100_001: cyvbUSDC; 19: KAT
        bytes32[] memory m14 = v.getMarketSubstrates(14);
        require(m14.length == 2, "market 14");
        require(v.getMarketSubstrates(100_001).length == 1, "market 100001");
        require(v.getMarketSubstrates(19).length == 1, "market 19");
        // dependencies to market 7 (F12)
        uint256[4] memory dep = [uint256(12), 19, 100_001, 14];
        for (uint256 i; i < dep.length; ++i) {
            uint256[] memory g = v.getDependencyBalanceGraph(dep[i]);
            require(g.length == 1 && g[0] == 7, "dependency graph to market 7");
        }
        // the typed config of the custom fuses is exactly what the gate writes (R5)
        require(keccak256(abi.encode(v.getMarketSubstrates(ZERO_MARKET))) == keccak256(abi.encode(IGateSub(address(gate)).previewSubstrates(ZERO_MARKET))), "ZERO market");
        require(keccak256(abi.encode(v.getMarketSubstrates(12))) == keccak256(abi.encode(IGateSub(address(gate)).previewSubstrates(12))), "market 12");
    }

    // ---------------------------------------------------------------- the executor on the new stack

    function scenario_deployAssetsKeepsThePps() external {
        // DIAGNOSTIC ONLY: preserve production code; isolate deposit-fee vs management-fee vs accounting deltas.
        uint256 ppsBeforeDeposit = _ppsFresh();
        uint256 totalBefore = cy.totalAssets();
        uint256 supplyBefore = cy.totalSupply();
        uint256 unrealizedBefore = cy.getUnrealizedManagementFee();
        uint256 idleBefore = IErcFork(AVKAT).balanceOf(VAULT);
        uint256 feeSharesBefore = cy.balanceOf(_p2("withdrawManagerV2"));
        uint256 onboardingPendingBefore = wm.pendingOnboardingFeeShares();
        uint256 aliceBefore = cy.balanceOf(alice);
        // The original IPOR deposit realizes any management fee accrued before the
        // transaction. Compute exactly how many fee shares its own conversion would
        // mint BEFORE depositing, independently of post-deposit supply observations.
        uint256 expectedManagementFeeShares = cy.convertToShares(unrealizedBefore);
        uint256 quotedShares = cy.convertToShares(500e18);
        uint256 firstPreviewUserShares = cy.previewDeposit(500e18);
        uint256 actualShares = _depositAvkat(alice, 500e18);
        uint256 ppsAfterDeposit = _pps();
        uint256 totalAfterDeposit = cy.totalAssets();
        uint256 supplyAfterDeposit = cy.totalSupply();
        uint256 unrealizedAfter = cy.getUnrealizedManagementFee();
        uint256 idleAfter = IErcFork(AVKAT).balanceOf(VAULT);
        uint256 feeSharesAfter = cy.balanceOf(_p2("withdrawManagerV2"));
        uint256 onboardingPendingAfterFirst = wm.pendingOnboardingFeeShares();
        uint256 aliceAfter = cy.balanceOf(alice);
        // A same-block repeat separates one-time accrued management fees from a systematic
        // deposit/onboarding fee dilution. An identical amount is deposited by a second user
        // immediately, with NO warp, rebalance, or management action in between.
        uint256 secondQuotedShares = cy.convertToShares(500e18);
        uint256 secondPreviewUserShares = cy.previewDeposit(500e18);
        uint256 bobBefore = cy.balanceOf(bob);
        uint256 secondActualShares = _depositAvkat(bob, 500e18);
        uint256 ppsAfterSecondDeposit = _pps();
        uint256 totalAfterSecondDeposit = cy.totalAssets();
        uint256 supplyAfterSecondDeposit = cy.totalSupply();
        uint256 unrealizedAfterSecond = cy.getUnrealizedManagementFee();
        uint256 idleAfterSecond = IErcFork(AVKAT).balanceOf(VAULT);
        uint256 feeSharesAfterSecond = cy.balanceOf(_p2("withdrawManagerV2"));
        uint256 onboardingPendingAfterSecond = wm.pendingOnboardingFeeShares();
        uint256 bobAfter = cy.balanceOf(bob);
        uint256 firstSupplyDelta = supplyAfterDeposit - supplyBefore;
        uint256 secondSupplyDelta = supplyAfterSecondDeposit - supplyAfterDeposit;
        uint256 firstUserMint = aliceAfter - aliceBefore;
        uint256 secondUserMint = bobAfter - bobBefore;
        uint256 firstWmMint = feeSharesAfter - feeSharesBefore;
        uint256 secondWmMint = feeSharesAfterSecond - feeSharesAfter;
        console2.log("V12 diagnostic: two 500 AVKAT deposits in the same block, no warp");
        console2.log("V12 PRE total assets", totalBefore);
        console2.log("V12 PRE total supply", supplyBefore);
        console2.log("V12 PRE management fee in assets", unrealizedBefore);
        console2.log("V12 PRE vault idle AVKAT", idleBefore);
        console2.log("V12 PRE WM shares", feeSharesBefore);
        console2.log("V12 PRE onboarding pending shares", onboardingPendingBefore);
        console2.log("V12 FIRST deposit gross quoted shares", quotedShares);
        console2.log("V12 FIRST deposit preview net user shares", firstPreviewUserShares);
        console2.log("V12 FIRST deposit return shares", actualShares);
        console2.log("V12 FIRST user share minted", firstUserMint);
        console2.log("V12 FIRST WM share minted", firstWmMint);
        console2.log("V12 FIRST total supply delta", firstSupplyDelta);
        console2.log("V12 FIRST other minted shares", firstSupplyDelta >= firstUserMint + firstWmMint ? firstSupplyDelta - firstUserMint - firstWmMint : 0);
        console2.log("V13 expected management fee shares", expectedManagementFeeShares);
        console2.log("V12 FIRST onboarding pending shares", onboardingPendingAfterFirst);
        console2.log("V12 FIRST management fee remaining", unrealizedAfter);
        console2.log("V12 SECOND deposit gross quoted shares", secondQuotedShares);
        console2.log("V12 SECOND deposit preview net user shares", secondPreviewUserShares);
        console2.log("V12 SECOND deposit return shares", secondActualShares);
        console2.log("V12 SECOND user shares minted", secondUserMint);
        console2.log("V12 SECOND WM shares minted", secondWmMint);
        console2.log("V12 SECOND total supply delta", secondSupplyDelta);
        console2.log("V12 SECOND other minted shares", secondSupplyDelta >= secondUserMint + secondWmMint ? secondSupplyDelta - secondUserMint - secondWmMint : 0);
        console2.log("V12 SECOND onboarding pending shares", onboardingPendingAfterSecond);
        console2.log("V12 SECOND management fee remaining", unrealizedAfterSecond);
        console2.log("V12 FIRST total assets delta", totalAfterDeposit - totalBefore);
        console2.log("V12 SECOND total assets delta", totalAfterSecondDeposit - totalAfterDeposit);
        console2.log("V12 FIRST idle AVKAT delta", idleAfter - idleBefore);
        console2.log("V12 SECOND idle AVKAT delta", idleAfterSecond - idleAfter);
        // Strict fee-adjusted economic baseline: the reported PPS should drop ONLY
        // by the authorized IPOR management-fee shares, not by the deposit itself.
        uint256 feeAdjustedPps = totalBefore * CY / (supplyBefore + expectedManagementFeeShares);
        console2.log("V13 fee-adjusted baseline PPS", feeAdjustedPps);
        console2.log("V12 FIRST PPS before", ppsBeforeDeposit);
        console2.log("V12 FIRST PPS after", ppsAfterDeposit);
        console2.log("V12 SECOND PPS after", ppsAfterSecondDeposit);
        console2.log("V12 FIRST PPS drop *1e8 / before", ppsBeforeDeposit > ppsAfterDeposit ? (ppsBeforeDeposit - ppsAfterDeposit) * 1e8 / ppsBeforeDeposit : 0);
        console2.log("V12 SECOND PPS drop *1e8 / before", ppsAfterDeposit > ppsAfterSecondDeposit ? (ppsAfterDeposit - ppsAfterSecondDeposit) * 1e8 / ppsAfterDeposit : 0);
        console2.log("V11 PRE totals assets", totalBefore);
        console2.log("V11 PRE total supply", supplyBefore);
        console2.log("V11 PRE unrealized management fee", unrealizedBefore);
        console2.log("V11 PRE vault idle avKAT", idleBefore);
        console2.log("V11 PRE WM shares", feeSharesBefore);
        console2.log("V11 quoted gross shares", quotedShares);
        console2.log("V11 actual receiver shares", actualShares);
        console2.log("V11 actual alice share delta", aliceAfter - aliceBefore);
        console2.log("V11 POST totals assets", totalAfterDeposit);
        console2.log("V11 POST total supply", supplyAfterDeposit);
        console2.log("V11 POST unrealized management fee", unrealizedAfter);
        console2.log("V11 POST vault idle avKAT", idleAfter);
        console2.log("V11 POST WM fee share delta", feeSharesAfter - feeSharesBefore);
        console2.log("V11 ASSETS delta", totalAfterDeposit - totalBefore);
        console2.log("V11 SUPPLY delta", supplyAfterDeposit - supplyBefore);
        vm.prank(keeper);
        exec.deployAssets();
        uint256 ppsAfterDeploy = _pps();
        console2.log("V11 PPS before deposit", ppsBeforeDeposit);
        console2.log("V11 PPS after first deposit", ppsAfterDeposit);
        console2.log("V12 PPS after second deposit", ppsAfterSecondDeposit);
        console2.log("V11 PPS after deployAssets", ppsAfterDeploy);
        // The expected-management-fee mint is derived independently from the
        // PRE-deposit IPOR fee calculation. Do not allow unrelated share minting to
        // masquerade as management fees or onboarding fees.
        require(firstSupplyDelta >= firstUserMint + firstWmMint, "FIRST SUPPLY ACCOUNTING MISMATCH");
        require(firstSupplyDelta - firstUserMint - firstWmMint == expectedManagementFeeShares,
            "UNACCOUNTED SHARES MINTED ON FIRST DEPOSIT");
        require(secondSupplyDelta == secondUserMint + secondWmMint,
            "UNACCOUNTED SHARES MINTED ON SECOND DEPOSIT");
        require(onboardingPendingAfterFirst - onboardingPendingBefore == firstWmMint,
            "FIRST ONBOARDING FEE SHARES MISMATCH");
        require(onboardingPendingAfterSecond - onboardingPendingAfterFirst == secondWmMint,
            "SECOND ONBOARDING FEE SHARES MISMATCH");
        require(totalAfterDeposit - totalBefore == 500e18 && totalAfterSecondDeposit - totalAfterDeposit == 500e18,
            "DEPOSIT ASSETS DID NOT FULLY ENTER VAULT");
        require(ppsAfterDeposit + 2 >= feeAdjustedPps,
            "FIRST DEPOSIT LOWERS PPS BEYOND MANAGEMENT FEE");
        require(ppsAfterSecondDeposit + 2 >= ppsAfterDeposit,
            "SECOND DEPOSIT LOWERS PPS AFTER MANAGEMENT FEE REALIZED");
        require(ppsAfterDeploy + 2 >= ppsAfterSecondDeposit,
            "DEPLOY ASSETS LOWERS PPS");
    }

    /// @notice E5: a post-bundle guard must refuse a transfer that lowers PPS.
    /// The recipient and token are permitted substrates; only the PPS guard fails.
    function scenario_guardBlocksPpsLoss() external {
        _depositAvkat(alice, 10e18);
        uint256[] memory markets = new uint256[](0);
        bytes32[] memory morpho = new bytes32[](0);
        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = FuseAction(_p2("guardFuse"), abi.encodeCall(CurveYieldBundleGuardFuse.enter,
            (CurveYieldBundleGuardFuseEnterData({markets: markets}))));
        actions[1] = FuseAction(_p2("transferFuse"), abi.encodeCall(CurveYieldErc20TransferFuse.enter,
            (CurveYieldErc20TransferFuseEnterData({
                token: AVKAT, to: 0xe7D109Ce6b34447Dd45B54e5615F4177291D5ADf, amount: 1e18
            }))));
        actions[2] = FuseAction(_p2("guardFuse"), abi.encodeCall(CurveYieldBundleGuardFuse.exit,
            (CurveYieldBundleGuardFuseExitData({
                markets: markets, maxPpsDropBps: 0, minAssetsPerShareDelta: 0,
                minIdleAssets: 0, morphoMarkets: morpho
            }))));
        uint256 beforeAssets = cy.totalAssets();
        vm.prank(DEPLOYER);
        // Current Foundry compares entire custom-error returndata; assert the exact
        // custom-error selector while allowing its runtime PPS values to vary by block.
        try cy.execute(actions) {
            revert("GUARD_DID_NOT_REVERT");
        } catch (bytes memory revertData) {
            require(revertData.length >= 4, "GUARD_EMPTY_REVERT");
            require(bytes4(revertData) == CurveYieldBundleGuardFuse.CurveYieldBundleGuardFusePpsDropped.selector,
                "GUARD_WRONG_REVERT");
        }
        assertEq(cy.totalAssets(), beforeAssets, "failed bundle changed vault assets");
    }

    /// @notice D5: detached legacy installer must not disable signing or ordinary IPOR base routing.
    function scenario_questStillActiveAfterM4() external {
        string memory record = vm.readFile(questsPath);
        address wrapper = vm.parseJsonAddress(record, ".base1271");
        address oldInstaller = vm.parseJsonAddress(record, ".signatureFuse");
        address config = vm.parseJsonAddress(record, ".configFuse");
        require(!v.isFuseSupported(oldInstaller), "legacy Quest installer reappeared");
        require(v.isFuseSupported(config), "revised Quest config unregistered");
        (bool ok, bytes memory baseData) = VAULT.staticcall(abi.encodeWithSignature("PLASMA_VAULT_BASE()"));
        require(ok && abi.decode(baseData, (address)) == wrapper, "active Quest base changed");
        bytes memory assetData;
        (ok, assetData) = VAULT.staticcall(abi.encodeWithSignature("asset()"));
        require(ok && abi.decode(assetData, (address)) == AVKAT, "original IPOR base no longer handles asset()");
    }

    function test_conformance() public {
        _runS("removals and market map", this.scenario_removalsAndMarketMap.selector);
        _runS("deployAssets keeps the share price", this.scenario_deployAssetsKeepsThePps.selector);
        _runS("guard rejects a PPS drop", this.scenario_guardBlocksPpsLoss.selector);
        _runS("Quest V2 still active after M4", this.scenario_questStillActiveAfterM4.selector);
        _tearDownFiles();
        _finish();
    }
}
