// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface ICyavKatRate {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @title CurveYieldWrappedCyavKat (wcyavKAT)
/// @notice ERC-4626 wrapper over cyavKAT, used as Morpho collateral. No pause, no upgrade; the owner can only set the two
/// fees, within hard caps. After Phase 3 the owner is the governance gate, where `setFees` is a protected call (fee
/// authority only: the DAO can never change or reduce these admin fees). Fees, taken in cyavKAT and sent to FEE_SPLITTER:
///   - management: managementFeeBps a year of the cyavKAT held (default 2%, max 5%)
///   - performance: performanceFeeBps of the cyavKAT share-price gain (avKAT per share) above a global high watermark
///     (default 8%, max 15%)
/// A fee change accrues first at the old rates, so a new rate never applies to past time.
/// `totalAssets()` is net of fees accrued but not yet taken, so the exchange rate (and any oracle reading it) never
/// jumps when fees are collected. `accrue()` is public and runs before every deposit / mint / withdraw / redeem.
contract CurveYieldWrappedCyavKat is ERC4626, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 500; // 5% a year
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 1_500; // 15% of gains above the watermark
    uint256 public constant YEAR = 365 days;

    uint256 public managementFeeBps = 200; // 2% a year
    uint256 public performanceFeeBps = 800; // 8% of gains above the watermark

    address public immutable FEE_SPLITTER;
    uint256 public immutable ONE_SHARE; // 10**cyavKAT decimals

    /// @notice High watermark: avKAT value of one cyavKAT at the last performance-fee accrual.
    uint256 public highWatermark;
    uint256 public lastAccrual;

    event FeesAccrued(uint256 managementShares, uint256 performanceShares, uint256 highWatermark);
    event FeesUpdated(uint256 managementFeeBps, uint256 performanceFeeBps);

    error InvalidAddress();
    error FeeTooHigh();

    constructor(address owner_, IERC20 cyavkat_, address feeSplitter_)
        ERC20("Wrapped CurveYield avKAT", "wcyavKAT")
        ERC4626(cyavkat_)
        Ownable(owner_)
    {
        if (address(cyavkat_) == address(0) || feeSplitter_ == address(0)) revert InvalidAddress();
        FEE_SPLITTER = feeSplitter_;
        ONE_SHARE = 10 ** ICyavKatRate(address(cyavkat_)).decimals();
        highWatermark = ICyavKatRate(address(cyavkat_)).convertToAssets(ONE_SHARE);
        lastAccrual = block.timestamp;
    }

    // ---------------------------------------------------------------- fees

    /// @notice Fees accrued since the last accrual, in cyavKAT shares (management, performance).
    function pendingFees() public view returns (uint256 management_, uint256 performance_) {
        uint256 held = IERC20(asset()).balanceOf(address(this));
        if (held == 0) return (0, 0);
        management_ = Math.mulDiv(held, managementFeeBps * (block.timestamp - lastAccrual), BPS * YEAR);
        if (management_ > held) management_ = held;
        uint256 price = ICyavKatRate(asset()).convertToAssets(ONE_SHARE);
        if (price > highWatermark) {
            // gain in avKAT = remaining * (price - hwm) / ONE_SHARE; fee in shares = 8% * gain / (price / ONE_SHARE)
            performance_ = Math.mulDiv(held - management_, (price - highWatermark) * performanceFeeBps, price * BPS);
        }
    }

    /// @notice Takes the accrued fees (cyavKAT to the fee splitter) and raises the watermark.
    function accrue() public {
        (uint256 management, uint256 performance) = pendingFees();
        uint256 price = ICyavKatRate(asset()).convertToAssets(ONE_SHARE);
        if (price > highWatermark) highWatermark = price;
        lastAccrual = block.timestamp;
        uint256 fee = management + performance;
        if (fee != 0) IERC20(asset()).safeTransfer(FEE_SPLITTER, fee);
        emit FeesAccrued(management, performance, highWatermark);
    }

    /// @notice Sets both fees (bps). Accrues first at the old rates.
    function setFees(uint256 managementFeeBps_, uint256 performanceFeeBps_) external onlyOwner {
        if (managementFeeBps_ > MAX_MANAGEMENT_FEE_BPS || performanceFeeBps_ > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh();
        accrue();
        managementFeeBps = managementFeeBps_;
        performanceFeeBps = performanceFeeBps_;
        emit FeesUpdated(managementFeeBps_, performanceFeeBps_);
    }

    // ---------------------------------------------------------------- ERC-4626 (net of pending fees)

    function totalAssets() public view override returns (uint256) {
        (uint256 management, uint256 performance) = pendingFees();
        return IERC20(asset()).balanceOf(address(this)) - management - performance;
    }

    function deposit(uint256 assets_, address receiver_) public override returns (uint256) {
        accrue();
        return super.deposit(assets_, receiver_);
    }

    function mint(uint256 shares_, address receiver_) public override returns (uint256) {
        accrue();
        return super.mint(shares_, receiver_);
    }

    function withdraw(uint256 assets_, address receiver_, address owner_) public override returns (uint256) {
        accrue();
        return super.withdraw(assets_, receiver_, owner_);
    }

    function redeem(uint256 shares_, address receiver_, address owner_) public override returns (uint256) {
        accrue();
        return super.redeem(shares_, receiver_, owner_);
    }
}
