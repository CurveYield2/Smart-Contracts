// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FuseAction} from "../../src/withdraw/interfaces/CurveYieldKatanaInterfaces.sol";

contract MockAsset is ERC20 {
    constructor() ERC20("asset", "AST") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @dev Stand-in for the AccessManager the WM's `_checkTemplatePermission` consults: `canCall(caller, target, selector)`.
/// One admin address is allowed on every (target, selector); everyone else is refused.
contract MockAccessManager {
    address public admin;

    constructor(address admin_) {
        admin = admin_;
    }

    function setAdmin(address admin_) external {
        admin = admin_;
    }

    function canCall(address caller_, address, bytes4) external view returns (bool immediate, uint32 delay) {
        return (caller_ == admin, 0);
    }
}

/// @dev Stand-in for the vault the WM is attached to: implements just enough of ERC4626 + IPlasmaVaultKatana for the
/// WM's own accounting to run (fee escrow, refunds, splits, custody cuts). `execute` runs each FuseAction as a plain
/// external call (not a delegatecall): the WM only requires that the call succeeds, never inspects the vault's own
/// ledger, so the mock fuses below only need to not revert.
contract MockPlasmaVault {
    MockAsset public immutable ASSET;
    uint256 public rateNum = 1;
    uint256 public rateDen = 1; // convertToAssets(shares) = shares * rateNum / rateDen

    constructor(MockAsset asset_) {
        ASSET = asset_;
    }

    function setRate(uint256 num_, uint256 den_) external {
        (rateNum, rateDen) = (num_, den_);
    }

    function asset() external view returns (address) {
        return address(ASSET);
    }

    function convertToAssets(uint256 shares_) external view returns (uint256) {
        return shares_ * rateNum / rateDen;
    }

    function convertToShares(uint256 assets_) external view returns (uint256) {
        return assets_ * rateDen / rateNum;
    }

    function previewRedeem(uint256 shares_) external view returns (uint256) {
        return shares_ * rateNum / rateDen;
    }

    function execute(FuseAction[] calldata actions_) external {
        for (uint256 i; i < actions_.length; ++i) {
            (bool ok, bytes memory ret) = actions_[i].fuse.call(actions_[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

/// @dev Stand-in for the request-fee fuse: `moveRequestFeeShares` / `configureManagerAssetAllowance` are pure bookkeeping
/// hooks the WM calls through `execute`; the mock only needs to accept them and record the call for assertions.
contract MockRequestFeeFuse {
    struct Move {
        address from;
        address to;
        uint256 amount;
    }

    Move[] public moves;
    address public lastPreviousManager;

    function movesLength() external view returns (uint256) {
        return moves.length;
    }

    function moveAmount(uint256 i_) external view returns (uint256) {
        return moves[i_].amount;
    }

    function moveRequestFeeShares(address from_, address to_, uint256 amount_) external {
        moves.push(Move(from_, to_, amount_));
    }

    function configureManagerAssetAllowance(address previousManager_) external {
        lastPreviousManager = previousManager_;
    }
}

/// @dev Stand-in for the burn-request-fee fuse: `enter((uint256))` is the burn hook the WM calls through `execute`. The
/// selector is that of a single-field STRUCT argument, not a plain uint256, so the mock must match the tuple shape.
struct BurnHeldSharesEnterData {
    uint256 maxShares;
}

contract MockBurnFuse {
    uint256[] public burned;

    function burnedLength() external view returns (uint256) {
        return burned.length;
    }

    function enter(BurnHeldSharesEnterData calldata data_) external {
        burned.push(data_.maxShares);
    }
}

/// @dev Stand-in for a POL / growth custody used by the single-recipient (non-split) fee path: `revenueShareBps`.
contract MockProfitCustody {
    uint16 public revenueShareBps;

    function setRevenueShareBps(uint16 bps_) external {
        revenueShareBps = bps_;
    }
}
