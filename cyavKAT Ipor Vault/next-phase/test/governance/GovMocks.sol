// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {
    IAragonTokenVoting, AragonProposalParameters, AragonTally, AragonAction, AragonTargetConfig
} from "../../src/governance/CurveYieldAragonInterfaces.sol";

contract GovMockToken is ERC20 {
    constructor(string memory n_) ERC20(n_, n_) {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @dev Mock Aragon TokenVoting: implements getProposal / getVoteOption exactly as the interface.
contract MockTokenVoting is IAragonTokenVoting {
    struct P {
        bool open;
        bool executed;
        AragonProposalParameters params;
        AragonTally tally;
        AragonAction[] actions;
    }

    mapping(uint256 => P) internal _p;
    mapping(uint256 => mapping(address => uint8)) internal _votes;

    function setProposal(
        uint256 id_, bool open_, bool executed_, uint64 snapshot_, uint64 endDate_, uint256 yes_, uint256 no_, uint256 abstain_
    ) external {
        P storage p = _p[id_];
        p.open = open_;
        p.executed = executed_;
        p.params.snapshotTimepoint = snapshot_;
        p.params.endDate = endDate_;
        p.tally = AragonTally(abstain_, yes_, no_);
    }

    function setActions(uint256 id_, AragonAction[] memory actions_) external {
        P storage p = _p[id_];
        delete p.actions;
        for (uint256 i; i < actions_.length; ++i) p.actions.push(actions_[i]);
    }

    function setVote(uint256 id_, address voter_, uint8 option_) external {
        _votes[id_][voter_] = option_;
    }

    function getVoteOption(uint256 id_, address voter_) external view returns (uint8) {
        return _votes[id_][voter_];
    }

    function getProposal(uint256 id_)
        external
        view
        returns (
            bool open_,
            bool executed_,
            AragonProposalParameters memory parameters_,
            AragonTally memory tally_,
            AragonAction[] memory actions_,
            uint256 allowFailureMap_,
            AragonTargetConfig memory targetConfig_
        )
    {
        P storage p = _p[id_];
        return (p.open, p.executed, p.params, p.tally, p.actions, 0, AragonTargetConfig(address(0), 0));
    }
}

/// @dev Ownable target with a setter, an admin setter and a no-arg action.
contract GovMockTarget is Ownable {
    uint256 public value;
    address public admin;
    uint256 public pings;
    address public lastCaller;

    constructor(address owner_) Ownable(owner_) {}

    function setter(uint256 v_) external {
        value = v_;
        lastCaller = msg.sender;
    }

    function setAdmin(address a_) external {
        admin = a_;
        lastCaller = msg.sender;
    }

    function ping() external {
        ++pings;
        lastCaller = msg.sender;
    }
}

/// @dev Records role management calls like an OZ AccessManager, with the same Multicall surface (IPOR's
/// IporFusionAccessManager extends OZ AccessManager, which inherits Multicall).
contract MockAccessManager {
    using Address for address;

    struct Call {
        bytes4 sel;
        uint64 a;
        uint64 b;
        address who;
        address caller;
    }

    Call[] public calls;
    address public lastClosedTarget;
    bool public lastClosed;
    address public lastCloseCaller;
    uint256 public closeCalls;

    function callsLength() external view returns (uint256) {
        return calls.length;
    }

    function grantRole(uint64 role_, address account_, uint32) external {
        calls.push(Call(msg.sig, role_, 0, account_, msg.sender));
    }

    function revokeRole(uint64 role_, address account_) external {
        calls.push(Call(msg.sig, role_, 0, account_, msg.sender));
    }

    function renounceRole(uint64 role_, address account_) external {
        calls.push(Call(msg.sig, role_, 0, account_, msg.sender));
    }

    function setRoleAdmin(uint64 role_, uint64 admin_) external {
        calls.push(Call(msg.sig, role_, admin_, address(0), msg.sender));
    }

    function setRoleGuardian(uint64 role_, uint64 guardian_) external {
        calls.push(Call(msg.sig, role_, guardian_, address(0), msg.sender));
    }

    function setGrantDelay(uint64 role_, uint32) external {
        calls.push(Call(msg.sig, role_, 0, address(0), msg.sender));
    }

    function setTargetFunctionRole(address target_, bytes4[] calldata, uint64 role_) external {
        calls.push(Call(msg.sig, role_, 0, target_, msg.sender));
    }

    function labelRole(uint64 role_, string calldata) external {
        calls.push(Call(msg.sig, role_, 0, address(0), msg.sender));
    }

    function updateTargetClosed(address target_, bool closed_) external {
        lastClosedTarget = target_;
        lastClosed = closed_;
        lastCloseCaller = msg.sender;
        ++closeCalls;
    }

    /// @dev Like OZ AccessManager.execute: calls `target_` with `data_` as the manager itself (permission already checked
    /// for the caller; the gate holds the admin roles). A call to the manager itself carries msg.sender == the manager.
    function execute(address target_, bytes calldata data_) external payable returns (uint32) {
        target_.functionCall(data_);
        return 0;
    }

    /// @dev Same as OZ Multicall: delegatecalls itself, so msg.sender of every inner call is the outer caller.
    function multicall(bytes[] calldata data_) external returns (bytes[] memory results_) {
        results_ = new bytes[](data_.length);
        for (uint256 i; i < data_.length; ++i) results_[i] = address(this).functionDelegateCall(data_[i]);
    }
}
