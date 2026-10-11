// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalHooksConfig} from "../../src/router/CurveYieldSwapRouterV2.sol";

contract MockErc20 is ERC20 {
    constructor(string memory n_) ERC20(n_, n_) {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @dev Stand-in for the governance gate's config side: router.protectionBps / router.twapWindow.
contract MockConfigGate {
    mapping(bytes32 => uint256) public values;

    function set(bytes32 key_, uint256 value_) external {
        values[key_] = value_;
    }

    function getMany(bytes32[] calldata keys_) external view returns (uint256[] memory out_) {
        out_ = new uint256[](keys_.length);
        for (uint256 i; i < keys_.length; ++i) out_[i] = values[keys_[i]];
    }
}

/// @dev Stand-in for the CurveYield DEX (Balancer V3) vault: only `getHooksConfig` is used by the router.
contract MockBalVault {
    mapping(address => address) public hookOf;

    function setHook(address pool_, address hook_) external {
        hookOf[pool_] = hook_;
    }

    function getHooksConfig(address pool_) external view returns (BalHooksConfig memory cfg_) {
        cfg_.hooksContract = hookOf[pool_];
    }
}

/// @dev Stand-in for the pool hook's time-weighted quote.
contract MockPoolHook {
    uint256 public expectedOut;

    function setExpectedOut(uint256 v_) external {
        expectedOut = v_;
    }

    function quoteOracleProtectedSwapOut(address, address, address, uint256)
        external view returns (uint256 oracleExpectedAmountOut, uint256 oracleMinAmountOut)
    {
        return (expectedOut, expectedOut);
    }
}

/// @dev Stand-in for Permit2: the router only ever calls `approve` (no-op here); `pull` moves tokens using the ERC20
/// allowance the swap router granted to this mock (the real Permit2 does exactly that, via its own bookkeeping).
contract MockPermit2 {
    function approve(address, address, uint160, uint48) external {}

    function pull(address token_, address from_, address to_, uint256 amount_) external {
        IERC20(token_).transferFrom(from_, to_, amount_);
    }
}

/// @dev Stand-in for the CurveYield DEX router: pulls tokenIn via the mock Permit2, pays out a settable tokenOut amount.
contract MockBalRouter {
    MockPermit2 public immutable PERMIT2;
    uint256 public nextOut;

    constructor(MockPermit2 permit2_) {
        PERMIT2 = permit2_;
    }

    function setNextOut(uint256 v_) external {
        nextOut = v_;
    }

    function getPermit2() external view returns (address) {
        return address(PERMIT2);
    }

    function swapSingleTokenExactIn(
        address, address tokenIn_, address tokenOut_, uint256 exactAmountIn_, uint256, uint256, bool, bytes calldata
    ) external returns (uint256 amountOut_) {
        PERMIT2.pull(tokenIn_, msg.sender, address(this), exactAmountIn_);
        amountOut_ = nextOut;
        MockErc20(tokenOut_).mint(msg.sender, amountOut_);
    }
}
