// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    CurveYieldBundleGuardFuse,
    CurveYieldBundleGuardFuseEnterData,
    CurveYieldBundleGuardFuseExitData
} from "../../src/generic/CurveYieldBundleGuardFuse.sol";

contract ManagementPpsTestAsset is ERC20 {
    constructor() ERC20("Test avKAT", "avKAT") {}
    function mint(address to_, uint256 amount_) external { _mint(to_, amount_); }
    function burn(address from_, uint256 amount_) external { _burn(from_, amount_); }
}

/// @dev Delegatecall fixture exercises the guard in vault storage context, as IPOR execute does.
/// It intentionally exposes free minting to prove the guard STILL rejects non-fee dilution.
contract ManagementPpsMockVault {
    ManagementPpsTestAsset public immutable TOKEN;
    CurveYieldBundleGuardFuse public immutable GUARD;
    uint256 public totalSupply;
    uint256 public unrealizedManagementFee;

    constructor(ManagementPpsTestAsset token_, CurveYieldBundleGuardFuse guard_) {
        TOKEN = token_;
        GUARD = guard_;
    }

    function asset() external view returns (address) { return address(TOKEN); }
    function convertToShares(uint256 assets_) external view returns (uint256) {
        return Math.mulDiv(assets_, totalSupply, TOKEN.balanceOf(address(this)));
    }
    function getUnrealizedManagementFee() external view returns (uint256) { return unrealizedManagementFee; }
    function initialize(uint256 shares_, uint256 feeAssets_) external {
        totalSupply = shares_;
        unrealizedManagementFee = feeAssets_;
    }
    function crystallize() external {
        uint256 shares_ = Math.mulDiv(unrealizedManagementFee, totalSupply, TOKEN.balanceOf(address(this)));
        totalSupply += shares_;
        unrealizedManagementFee = 0;
    }
    function mintUnrelated(uint256 shares_) external { totalSupply += shares_; }
    function begin() public {
        uint256[] memory markets = new uint256[](0);
        _delegate(abi.encodeCall(CurveYieldBundleGuardFuse.enter, (CurveYieldBundleGuardFuseEnterData(markets))));
    }
    function finish() public {
        uint256[] memory markets = new uint256[](0);
        bytes32[] memory morphoMarkets = new bytes32[](0);
        _delegate(abi.encodeCall(CurveYieldBundleGuardFuse.exit,
            (CurveYieldBundleGuardFuseExitData(markets, 0, 0, 0, morphoMarkets))));
    }
    // All actions MUST occur in one EVM transaction: transient TSTORE/TLOAD is transaction-scoped.
    function runScenario(bool realizeFee_, bool additionalMint_, bool destroyAssets_) external {
        begin();
        if (realizeFee_) this.crystallize();
        if (additionalMint_) this.mintUnrelated(1e18);
        if (destroyAssets_) TOKEN.burn(address(this), 1e18);
        finish();
    }

    function _delegate(bytes memory data_) private {
        (bool ok, bytes memory ret) = address(GUARD).delegatecall(data_);
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
    }
}

contract ManagementFeePpsGuardTest is Test {
    ManagementPpsTestAsset token;
    CurveYieldBundleGuardFuse guard;
    ManagementPpsMockVault vault;

    function setUp() public {
        token = new ManagementPpsTestAsset();
        guard = new CurveYieldBundleGuardFuse(1, makeAddr("morpho"));
        vault = new ManagementPpsMockVault(token, guard);
        token.mint(address(vault), 1_000_000e18);
        vault.initialize(1_000_000e18, 1_000e18);
    }

    function test_accurateIporManagementFeeRealizationIsNeutral() public {
        vault.runScenario(true, false, false);
    }

    function _assertLossReverted(bool realized_, bool additionalMint_, bool destroyAssets_) private {
        try vault.runScenario(realized_, additionalMint_, destroyAssets_) {
            revert("non-management PPS loss incorrectly permitted");
        } catch (bytes memory reason) {
            assertGe(reason.length, 4, "missing guard revert selector");
            assertEq(bytes4(reason), CurveYieldBundleGuardFuse.CurveYieldBundleGuardFusePpsDropped.selector);
        }
    }

    function test_nonFeeShareDilutionStillRevertsWithoutRealization() public {
        _assertLossReverted(false, true, false);
    }

    function test_unrelatedExtraMintStillRevertsAlongsideManagementFee() public {
        _assertLossReverted(true, true, false);
    }

    function test_assetLossStillRevertsWhenManagementFeeRealizes() public {
        _assertLossReverted(true, false, true);
    }

    function test_feeUnrealizedAndNoOtherChangePasses() public {
        vault.runScenario(false, false, false);
    }
}
