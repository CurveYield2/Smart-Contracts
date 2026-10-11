// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {CurveYieldGovernanceGate} from "../../src/governance/CurveYieldGovernanceGate.sol";
import {IporRoleMock} from "./IporRoleMocks.sol";
contract IporSubstrateVaultMock {
    mapping(uint256 => bytes32[]) private stored;
    uint256 public writes;
    function grantMarketSubstrates(uint256 id,bytes32[] calldata list) external {
        delete stored[id];for(uint256 i;i<list.length;++i)stored[id].push(list[i]);++writes;
    }
    function get(uint256 id) external view returns (bytes32[] memory){return stored[id];}
}
contract GateSubstratesTest is Test {
    IporRoleMock am;
    CurveYieldGovernanceGate gate;
    IporSubstrateVaultMock vault;
    address owner=makeAddr("owner");
    address op=makeAddr("op");
    address stranger=makeAddr("stranger");
    bytes32 constant CAP=keccak256("test.cap");
    uint256 constant MARKET=12;
    function setUp() public {
        am=new IporRoleMock();gate=new CurveYieldGovernanceGate(address(am),owner);
        vault=new IporSubstrateVaultMock();am.setRole(1,owner,true,0);am.setRole(100,op,true,0);
        vm.startPrank(owner);
        gate.registerConfig(CAP,2,1,100,10);
        gate.setSubstrateVault(address(vault));
        bytes32[] memory entries=new bytes32[](1);entries[0]=bytes32(uint256(7));
        gate.setStaticSubstrates(MARKET,entries);
        gate.addSubstrateBinding(MARKET,CAP,gate.BIND_TRANSFER_CAP(),bytes32(uint256(uint160(owner))));
        vm.stopPrank();
    }
    function test_iporOwnerSetsBinding_operatorConfigSyncsMarket() public {
        bytes32[] memory keys=new bytes32[](1);keys[0]=CAP;
        uint256[] memory values=new uint256[](1);values[0]=20;
        vm.prank(op);gate.setConfigs(keys,values);
        bytes32[] memory afterWrite=vault.get(MARKET);
        assertEq(afterWrite.length,2);
        assertEq(vault.writes(),1);
        assertEq(uint256(afterWrite[1]) >> 248,0x12);
        assertEq((uint256(afterWrite[1]) >> 160) & ((uint256(1)<<88)-1),20);
    }
    function test_nonOwnerCannotRerouteSubstrates() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotIporRole.selector, uint64(1), stranger));
        gate.setSubstrateVault(stranger);
    }
    function test_permissionlessSyncWritesOnlyConfiguredList() public {
        vm.prank(stranger);
        gate.syncSubstrates(MARKET);
        bytes32[] memory list=vault.get(MARKET);
        bytes32[] memory expected=gate.previewSubstrates(MARKET);
        assertEq(keccak256(abi.encode(list)),keccak256(abi.encode(expected)));
    }
}
