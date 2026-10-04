// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveYieldGateConfig} from "../governance/CurveYieldGateConfig.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title CurveYieldPolFeeder (POL spec section 1)
/// @notice Sits in front of an avKAT destination and diverts a share of what passes through to the POL custody.
/// Two instances:
///   incoming feeder: loop profit splitter `growthCustody` -> this -> `polBps` (20%) POL custody, rest profit custody
///   yield feeder:    profit custody `feeRecipient`    -> this -> `polBps` (15%) POL custody, rest previous recipient
/// `distribute()` (anyone) splits the whole avKAT balance. Everything is reversible: point the source back at the
/// destination. The yield feeder carries admin fees, so its owner is the fee authority.
contract CurveYieldPolFeeder is Ownable2Step, CurveYieldGateConfig {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    IERC20 public immutable AVKAT;
    address public polCustody;
    address public destination; // where the rest goes (profit custody / previous fee recipient)
    bytes32 public immutable POL_BPS_KEY; // this feeder's share key in the governance gate (incoming / yield)

    event Distributed(uint256 toPol, uint256 toDestination);
    event ConfigUpdated(address polCustody, address destination);

    error InvalidConfig();

    constructor(address owner_, address avkat_, address polCustody_, address destination_, bytes32 polBpsKey_, address configGate_)
        Ownable(owner_)
        CurveYieldGateConfig(configGate_)
    {
        if (avkat_ == address(0) || polBpsKey_ == bytes32(0)) revert InvalidConfig();
        AVKAT = IERC20(avkat_);
        POL_BPS_KEY = polBpsKey_;
        _setConfig(polCustody_, destination_);
    }

    function setConfig(address polCustody_, address destination_) external onlyOwner {
        _setConfig(polCustody_, destination_);
    }

    /// @notice Share sent to the POL custody (bps), from the governance gate.
    function polBps() public view returns (uint256) {
        return _config1(POL_BPS_KEY);
    }

    function distribute() external {
        uint256 bal = AVKAT.balanceOf(address(this));
        if (bal == 0) return;
        uint256 toPol = bal * polBps() / BPS;
        uint256 toDestination = bal - toPol;
        if (toPol != 0) AVKAT.safeTransfer(polCustody, toPol);
        if (toDestination != 0) AVKAT.safeTransfer(destination, toDestination);
        emit Distributed(toPol, toDestination);
    }

    function _setConfig(address polCustody_, address destination_) private {
        if (polCustody_ == address(0) || destination_ == address(0) || destination_ == address(this)) revert InvalidConfig();
        (polCustody, destination) = (polCustody_, destination_);
        emit ConfigUpdated(polCustody_, destination_);
    }
}
