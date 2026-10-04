// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/**
 * @title CurveYield System Component
 * @notice CurveYield is a decentralized NGO building optimized DeFi systems for the good of all.
 *
 * @dev CurveYield integrates specialized AMM infrastructure, tokenized yield strategies, credit
 * markets, and protocol-owned liquidity into a unified, capital-efficient liquidity stack governed
 * by an open, international DAO community.
 *
 * Protocol operations are enhanced by cross-chain bridging and messaging, MEV capture systems,
 * off-chain to on-chain automation, and peer-to-peer data networks.
 *
 * This contract is one component of the CurveYield system.
 *
 * CurveYield uses proven DeFi primitives where possible and adds targeted coordination and
 * capital-efficiency-enhancing contracts where needed. Users and integrators must review
 * CurveYield documentation before use.
 *
 * Learn more:
 * Documentation: https://docs.curveyield.com
 * dApp: https://curveyield.online
 * GitHub: https://github.com/curveyield
 *
 * Decentralized links may have limited or delayed availability during periods of high network activity:
 * https://curveyield.eth.limo
 * https://curveyield.dao
 *
 * Note: curveyield.dao may require a Brave Browser or an Unstoppable Domains browser plugin to use.
 */

struct CurveYieldRequestAccounting {
    uint128 remainingShares;
    uint128 initialNetShares;
    uint128 totalFeeShares;
    uint128 earnedFeeShares;
    uint32 endWithdrawWindowTimestamp;
    uint64 generation;
    bool active;
}

struct CurveYieldRequestQueueEntry {
    address requester;
    uint32 endWithdrawWindowTimestamp;
    uint64 generation;
}

library CurveYieldWithdrawalManagerStorageLib {
    bytes32 private constant STORAGE_SLOT =
        0x899b0a3cba55c1eef7200696a434469663b972951218d64161922b65c4dc1000;

    struct Layout {
        mapping(address requester => CurveYieldRequestAccounting request) requests;
        CurveYieldRequestQueueEntry[] queue;
        uint256 activeRequestedShares;
        uint256 earnedFeeShares;
        address controller;
        address burnRequestFeeFuse;
        address requestFeeFuse;
        address profitCustody;
    }

    error EmptyQueue();

    function layout() internal pure returns (Layout storage result) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            result.slot := slot
        }
    }

    function push(CurveYieldRequestQueueEntry memory entry) internal {
        Layout storage state = layout();
        state.queue.push(entry);
        uint256 index = state.queue.length - 1;
        while (index != 0) {
            uint256 parent = (index - 1) >> 1;
            if (!_less(state.queue[index], state.queue[parent])) break;
            (state.queue[index], state.queue[parent]) = (state.queue[parent], state.queue[index]);
            index = parent;
        }
    }

    function peek() internal view returns (CurveYieldRequestQueueEntry memory) {
        Layout storage state = layout();
        if (state.queue.length == 0) revert EmptyQueue();
        return state.queue[0];
    }

    function pop() internal returns (CurveYieldRequestQueueEntry memory removed) {
        Layout storage state = layout();
        uint256 length = state.queue.length;
        if (length == 0) revert EmptyQueue();
        removed = state.queue[0];
        if (length == 1) {
            state.queue.pop();
            return removed;
        }

        state.queue[0] = state.queue[length - 1];
        state.queue.pop();
        uint256 index;
        length -= 1;
        while (true) {
            uint256 left = (index << 1) + 1;
            if (left >= length) break;
            uint256 right = left + 1;
            uint256 smallest = right < length && _less(state.queue[right], state.queue[left]) ? right : left;
            if (!_less(state.queue[smallest], state.queue[index])) break;
            (state.queue[index], state.queue[smallest]) = (state.queue[smallest], state.queue[index]);
            index = smallest;
        }
    }

    function queueLength() internal view returns (uint256) {
        return layout().queue.length;
    }

    function _less(
        CurveYieldRequestQueueEntry memory a,
        CurveYieldRequestQueueEntry memory b
    ) private pure returns (bool) {
        if (a.endWithdrawWindowTimestamp != b.endWithdrawWindowTimestamp) {
            return a.endWithdrawWindowTimestamp < b.endWithdrawWindowTimestamp;
        }
        if (a.requester != b.requester) return uint160(a.requester) < uint160(b.requester);
        return a.generation < b.generation;
    }
}
