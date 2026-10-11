// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// Stub for the existing IPOR Access Manager's role check only.
contract IporRoleMock {
    mapping(uint64 => mapping(address => bool)) private _members;
    mapping(uint64 => mapping(address => uint32)) private _delays;
    function setRole(uint64 roleId, address account, bool member, uint32 delay) external {
        _members[roleId][account] = member;
        _delays[roleId][account] = delay;
    }
    function hasRole(uint64 roleId, address account) external view returns (bool, uint32) {
        return (_members[roleId][account], _delays[roleId][account]);
    }
}

contract IporOwnedOperationalTarget is Ownable2Step {
    uint256 public value;
    address public adminReceiver;
    uint16 public feeBps;
    constructor(address owner_) Ownable(owner_) {}
    function updateValue(uint256 value_) external onlyOwner { value = value_; }
    function setAdminReceiver(address receiver_) external onlyOwner { adminReceiver = receiver_; }
    function setFeeBps(uint16 bps_) external onlyOwner { feeBps = bps_; }
}
