// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CurveYieldSwapLib} from "./CurveYieldSwapLib.sol";
import {CurveYieldPolPriceLib} from "./CurveYieldPolPriceLib.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";
import {CySushiRoute, IAlphaVault, ICyPolVault, ICyPolWithdrawManager} from "./CurveYieldPolInterfaces.sol";

struct CyPolCustodyVenues {
    address alphaVault; // our Charm Alpha Vault on the Sushi V3 0.3% cyavKAT/WETH pool
    address cyWethPool; // that Sushi pool (TWAP market reference)
    address polPool; // CurveYield DEX Gyro E-CLP cyavKAT/avKAT pool: the ONLY avKAT <-> cyavKAT venue
    address balancerRouter;
    address permit2;
    address sushiRouter;
    address sushiQuoter;
    address withdrawManager; // cyavKAT's withdraw manager (burn-only instant redemptions)
}

struct CyPolCustodyParams {
    uint32 twapWindow; // 30 min
    uint16 maxSlippageBps; // Sushi legs vs TWAP (100)
    uint16 maxPremiumBps; // never pay more than the deposit rate x (1 + this) for cyavKAT (0)
}

/// @title CurveYieldPolCustody (POL spec, position B)
/// @notice Off the vault's books. Receives avKAT from the POL feeders, buys cyavKAT (POL pool) and WETH (Sushi, best
/// of the configured routes, TWAP-guarded) and deposits them into our Alpha Vault. Exits go to the owner (fee Safe) as
/// avKAT - the cyavKAT leg by the cheaper of a market sale (only at or above its net value) and a burn-only instant
/// redemption (whole fee burned for holders). It never buys back or burns: only the vault's own cyavKAT/avKAT position
/// (position A) does that.
contract CurveYieldPolCustody is Ownable2Step, ReentrancyGuard, CurveYieldGateConfig {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    address public immutable VAULT; // cyavKAT
    address public immutable AVKAT;
    address public immutable WETH;
    address public immutable FEE_MANAGER; // cyavKAT's IPOR fee manager (net rate)

    CyPolCustodyVenues public venues;
    CySushiRoute[] private _avkatToWeth;
    CySushiRoute[] private _wethToAvkat;
    mapping(address => bool) public isOperator;

    event Deployed(uint256 avkatIn, uint256 cyavkatBought, uint256 wethBought, uint256 shares);
    event ExitedToAvkat(uint256 shares, uint256 avkatOut, bool cyavkatSold, address receiver);
    event Migrated(address indexed newCustody, uint256 alphaShares, uint256 avkat, uint256 cyavkat, uint256 weth);
    event OperatorSet(address indexed operator, bool enabled);
    event VenuesUpdated(CyPolCustodyVenues venues);
    event RoutesUpdated(uint256 avkatToWeth, uint256 wethToAvkat);

    error NotOperator(address caller);
    error BadParams();

    modifier onlyOperator() {
        if (msg.sender != owner() && !isOperator[msg.sender]) revert NotOperator(msg.sender);
        _;
    }

    constructor(address owner_, address vault_, address avkat_, address weth_, address feeManager_, address configGate_)
        Ownable(owner_)
        CurveYieldGateConfig(configGate_)
    {
        if (vault_ == address(0) || avkat_ == address(0) || weth_ == address(0) || feeManager_ == address(0)) revert BadParams();
        (VAULT, AVKAT, WETH, FEE_MANAGER) = (vault_, avkat_, weth_, feeManager_);
    }

    /// @notice The custody's settings, read from the governance gate.
    function params() public view returns (CyPolCustodyParams memory p_) {
        bytes32[] memory k = new bytes32[](3);
        (k[0], k[1], k[2]) = (K.POLC_TWAP_WINDOW, K.POLC_MAX_SLIPPAGE_BPS, K.POLC_MAX_PREMIUM_BPS);
        uint256[] memory v = _config(k);
        p_ = CyPolCustodyParams(uint32(v[0]), uint16(v[1]), uint16(v[2]));
    }

    // ---------------------------------------------------------------- configuration (owner = fee Safe)

    function setOperator(address operator_, bool enabled_) external onlyOwner {
        isOperator[operator_] = enabled_;
        emit OperatorSet(operator_, enabled_);
    }

    function setVenues(CyPolCustodyVenues calldata v_) external onlyOwner {
        if (v_.alphaVault == address(0) || v_.polPool == address(0) || v_.balancerRouter == address(0) ||
            v_.permit2 == address(0) || v_.sushiRouter == address(0) || v_.sushiQuoter == address(0) ||
            v_.withdrawManager == address(0)) revert BadParams();
        address t0 = IAlphaVault(v_.alphaVault).token0();
        address t1 = IAlphaVault(v_.alphaVault).token1();
        if (!((t0 == VAULT && t1 == WETH) || (t0 == WETH && t1 == VAULT))) revert BadParams();
        venues = v_;
        emit VenuesUpdated(v_);
    }

    /// @notice Candidate Sushi routes both ways (e.g. avKAT-KAT 1% -> KAT-WETH 0.05%, and
    /// avKAT-KAT 1% -> KAT-USDC 0.05% -> USDC-WETH 0.05%); every swap takes the best-quoted one.
    function setRoutes(CySushiRoute[] calldata avkatToWeth_, CySushiRoute[] calldata wethToAvkat_) external onlyOwner {
        delete _avkatToWeth;
        delete _wethToAvkat;
        for (uint256 i; i < avkatToWeth_.length; ++i) {
            _checkRoute(avkatToWeth_[i], AVKAT, WETH);
            _avkatToWeth.push(avkatToWeth_[i]);
        }
        for (uint256 i; i < wethToAvkat_.length; ++i) {
            _checkRoute(wethToAvkat_[i], WETH, AVKAT);
            _wethToAvkat.push(wethToAvkat_[i]);
        }
        emit RoutesUpdated(avkatToWeth_.length, wethToAvkat_.length);
    }

    function routes() external view returns (CySushiRoute[] memory avkatToWeth_, CySushiRoute[] memory wethToAvkat_) {
        return (_avkatToWeth, _wethToAvkat);
    }

    // ---------------------------------------------------------------- views

    function depositRate() public view returns (uint256) {
        return CurveYieldPolPriceLib.depositRate(VAULT, FEE_MANAGER);
    }

    function marketRate() public view returns (uint256) {
        return CurveYieldPolPriceLib.marketRate(VAULT, venues.cyWethPool, _wethToAvkat, params().twapWindow);
    }

    /// @notice (cyavKAT, WETH) held through the Alpha Vault.
    function position() public view returns (uint256 cyavkat_, uint256 weth_, uint256 shares_) {
        IAlphaVault a = IAlphaVault(venues.alphaVault);
        shares_ = a.balanceOf(address(this));
        uint256 supply = a.totalSupply();
        if (shares_ == 0 || supply == 0) return (0, 0, shares_);
        (uint256 t0, uint256 t1) = a.getTotalAmounts();
        (uint256 c, uint256 w) = a.token0() == VAULT ? (t0, t1) : (t1, t0);
        (cyavkat_, weth_) = (c * shares_ / supply, w * shares_ / supply);
    }

    // ---------------------------------------------------------------- operations

    /// @notice Buys cyavKAT (POL pool, never above the deposit rate x (1 + maxPremium)) and WETH (best Sushi route) at the
    /// Alpha Vault's current value ratio and deposits. `avkatIn_` 0 = all idle avKAT. Leftovers stay idle.
    function deploy(uint256 avkatIn_) external onlyOperator nonReentrant returns (uint256 shares_) {
        uint256 idle = IERC20(AVKAT).balanceOf(address(this));
        if (avkatIn_ == 0 || avkatIn_ > idle) avkatIn_ = idle;
        if (avkatIn_ == 0) return 0;
        CyPolCustodyVenues memory v = venues;
        CyPolCustodyParams memory p = params();

        // value split of the Alpha Vault (cyavKAT at the deposit rate, WETH at its TWAP value); empty vault = 50/50
        IAlphaVault a = IAlphaVault(v.alphaVault);
        (uint256 t0, uint256 t1) = a.getTotalAmounts();
        bool cyIs0 = a.token0() == VAULT;
        (uint256 c, uint256 w) = cyIs0 ? (t0, t1) : (t1, t0);
        uint256 cyVal = CurveYieldPolPriceLib.netValue(VAULT, FEE_MANAGER, c);
        uint256 wVal = w == 0 || _wethToAvkat.length == 0 ? 0 : CurveYieldSwapLib.twapOutRoute(_wethToAvkat[0], w, p.twapWindow);
        uint256 forCy = cyVal + wVal == 0 ? avkatIn_ / 2 : avkatIn_ * cyVal / (cyVal + wVal);

        uint256 cyBought = _buyCyavkat(v, forCy, p.maxPremiumBps == 0 ? BPS : BPS + p.maxPremiumBps);
        uint256 wethBought = CurveYieldSwapLib.swapBest(
            v.sushiRouter, v.sushiQuoter, _avkatToWeth, avkatIn_ - forCy, p.twapWindow, p.maxSlippageBps, address(this)
        );

        uint256 cyAll = IERC20(VAULT).balanceOf(address(this));
        uint256 wAll = IERC20(WETH).balanceOf(address(this));
        IERC20(VAULT).forceApprove(v.alphaVault, cyAll);
        IERC20(WETH).forceApprove(v.alphaVault, wAll);
        (shares_,,) = cyIs0 ? a.deposit(cyAll, wAll, 0, 0, address(this)) : a.deposit(wAll, cyAll, 0, 0, address(this));
        IERC20(VAULT).forceApprove(v.alphaVault, 0);
        IERC20(WETH).forceApprove(v.alphaVault, 0);
        emit Deployed(avkatIn_, cyBought, wethBought, shares_);
    }

    /// @notice Exit to avKAT for the owner. cyavKAT leg: sold in the POL pool only if that returns at least its net
    /// value (a gain for the vault), otherwise redeemed through the burn-only instant withdrawal (fee ignored: it is
    /// burned for holders; nothing goes to admin / custody).
    function exitToAvkat(uint256 shares_, address receiver_) external onlyOwner nonReentrant returns (uint256 avkatOut_) {
        (uint256 cy, uint256 w) = _withdraw(shares_);
        CyPolCustodyVenues memory v = venues;
        CurveYieldSwapLib.swapBest(
            v.sushiRouter, v.sushiQuoter, _wethToAvkat, w, params().twapWindow, params().maxSlippageBps, address(this)
        );
        bool sold;
        if (cy != 0) {
            uint256 floor = CurveYieldPolPriceLib.netValue(VAULT, FEE_MANAGER, cy);
            try this.sellCyavkatSelf(cy, floor) { sold = true; } catch {}
            if (!sold) {
                ICyPolWithdrawManager(v.withdrawManager).armBurnOnlyFee();
                ICyPolVault(VAULT).redeem(cy, address(this), address(this));
            }
        }
        avkatOut_ = IERC20(AVKAT).balanceOf(address(this));
        IERC20(AVKAT).safeTransfer(receiver_, avkatOut_);
        emit ExitedToAvkat(shares_, avkatOut_, sold, receiver_);
    }

    /// @dev External only so exitToAvkat can try/catch it; callable by this contract alone.
    function sellCyavkatSelf(uint256 cy_, uint256 minOut_) external {
        if (msg.sender != address(this)) revert NotOperator(msg.sender);
        CyPolCustodyVenues memory v = venues;
        CurveYieldSwapLib.balancerSwap(v.balancerRouter, v.permit2, v.polPool, VAULT, AVKAT, cy_, minOut_);
    }

    /// @notice Moves the whole position to a new custody (e.g. a future version): the Alpha Vault shares plus every
    /// avKAT, cyavKAT and WETH held. Owner only (fee authority through the governance gate).
    function migrate(address newCustody_) external onlyOwner nonReentrant {
        if (newCustody_ == address(0) || newCustody_ == address(this)) revert BadParams();
        address alpha = venues.alphaVault;
        uint256 shares = alpha == address(0) ? 0 : IAlphaVault(alpha).balanceOf(address(this));
        if (shares != 0) IERC20(alpha).safeTransfer(newCustody_, shares);
        address[3] memory tokens = [AVKAT, VAULT, WETH];
        uint256[3] memory moved;
        for (uint256 i; i < 3; ++i) {
            moved[i] = IERC20(tokens[i]).balanceOf(address(this));
            if (moved[i] != 0) IERC20(tokens[i]).safeTransfer(newCustody_, moved[i]);
        }
        emit Migrated(newCustody_, shares, moved[0], moved[1], moved[2]);
    }

    /// @notice Rescue anything else (owner only).
    function sweep(address token_, address to_, uint256 amount_) external onlyOwner {
        IERC20(token_).safeTransfer(to_, amount_);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Buys cyavKAT with avKAT in the POL pool, paying at most deposit rate x priceBps / BPS.
    function _buyCyavkat(CyPolCustodyVenues memory v_, uint256 avkatIn_, uint256 priceBps_) private returns (uint256) {
        if (avkatIn_ == 0) return 0;
        uint256 minOut = avkatIn_ * CurveYieldPolPriceLib.oneShare(VAULT) * BPS / (depositRate() * priceBps_);
        return CurveYieldSwapLib.balancerSwap(v_.balancerRouter, v_.permit2, v_.polPool, AVKAT, VAULT, avkatIn_, minOut);
    }

    function _withdraw(uint256 shares_) private returns (uint256 cy_, uint256 weth_) {
        IAlphaVault a = IAlphaVault(venues.alphaVault);
        uint256 held = a.balanceOf(address(this));
        if (shares_ == 0 || shares_ > held) shares_ = held;
        (uint256 o0, uint256 o1) = a.withdraw(shares_, 0, 0, address(this));
        (cy_, weth_) = a.token0() == VAULT ? (o0, o1) : (o1, o0);
    }

    function _checkRoute(CySushiRoute calldata r_, address from_, address to_) private pure {
        uint256 n = r_.pools.length;
        if (n == 0 || r_.tokens.length != n + 1 || r_.tokens[0] != from_ || r_.tokens[n] != to_ ||
            r_.path.length != 20 + 23 * n) revert BadParams();
    }

}
