// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {Id, Market, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {YearnMorphoMarketChild_v1} from "../contracts/YearnMorphoMarketChild_v1.sol";

contract MockRewardAssetChildV1 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_,symbol_) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockMorphoDirectMarketV1 {
    using MockUnitsForMarketChildV1 for uint256;

    MockRewardAssetChildV1 public immutable token;
    MarketParams private params;
    Market private data;
    mapping(address => uint256) private suppliedShares;
    Id public immutable marketId;

    constructor(address loanToken) {
        token = MockRewardAssetChildV1(loanToken);
        marketId = Id.wrap(bytes32(uint256(1)));
        params = MarketParams(loanToken,address(0xBEEF),address(0),address(0),0);
        data.lastUpdate = uint128(block.timestamp);
    }

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        require(Id.unwrap(id) == Id.unwrap(marketId), "market");
        return params;
    }

    function market(Id id) external view returns (Market memory) {
        require(Id.unwrap(id) == Id.unwrap(marketId), "market");
        return data;
    }

    function supplyShares(Id id, address account) external view returns (uint256) {
        require(Id.unwrap(id) == Id.unwrap(marketId), "market");
        return suppliedShares[account];
    }

    function supply(
        MarketParams calldata marketParams,
        uint256 assets, uint256 shares, address beneficiary, bytes calldata
    ) external returns (uint256 suppliedAssets, uint256 suppliedShares) {
        require(marketParams.loanToken == address(token) && shares == 0, "supply args");
        token.transferFrom(msg.sender,address(this),assets);
        // Proportional share issuance, accounting for any prior interest.
        suppliedShares = assets.toSharesDown(data.totalSupplyAssets,data.totalSupplyShares);
        suppliedShares[beneficiary] += suppliedShares;
        data.totalSupplyAssets += uint128(assets);
        data.totalSupplyShares += uint128(suppliedShares);
        suppliedAssets = assets;
    }

    function withdraw(
        MarketParams calldata marketParams, uint256 assets, uint256 shares,
        address beneficiary, address receiver
    ) external returns (uint256 withdrawnAssets, uint256 withdrawnShares) {
        require(marketParams.loanToken == address(token) && shares == 0, "withdraw args");
        withdrawnShares = assets.toSharesUp(data.totalSupplyAssets,data.totalSupplyShares);
        require(suppliedShares[beneficiary] >= withdrawnShares, "shares");
        suppliedShares[beneficiary] -= withdrawnShares;
        data.totalSupplyShares -= uint128(withdrawnShares);
        data.totalSupplyAssets -= uint128(assets);
        withdrawnAssets = assets;
        token.transfer(receiver,assets);
    }

    function accrueMockInterest(uint256 gain) external {
        token.mint(address(this), gain);
        data.totalSupplyAssets += uint128(gain);
    }

    function simulateBorrow(uint256 borrowed) external {
        require(borrowed <= data.totalSupplyAssets, "borrow too big");
        data.totalBorrowAssets = uint128(borrowed);
    }
}

library MockUnitsForMarketChildV1 {
    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares)
        internal pure returns (uint256)
    {
        return totalAssets == 0 ? assets : assets * totalShares / totalAssets;
    }
    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares)
        internal pure returns (uint256)
    {
        return totalAssets == 0 ? assets : (assets * totalShares + totalAssets - 1) / totalAssets;
    }
}

contract MockMerklChildV1 {
    MockRewardAssetChildV1 public immutable kat;
    constructor(address _kat) { kat = MockRewardAssetChildV1(_kat); }
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata
    ) external {
        for (uint256 i; i < users.length; ++i) {
            require(tokens[i] == address(kat), "token");
            kat.mint(users[i], amounts[i]);
        }
    }
}

contract MockRouterChildV1 {
    MockRewardAssetChildV1 public immutable kat;
    MockRewardAssetChildV1 public immutable vbUsdc;
    constructor(address _kat,address _asset) {
        kat = MockRewardAssetChildV1(_kat);
        vbUsdc = MockRewardAssetChildV1(_asset);
    }
    function routeFor(address, address) external pure returns (bytes memory) { return hex"01"; }
    function swapExactInput(
        address, address, uint256 amountIn, uint256 minAmountOut,
        address recipient, uint256 deadline
    ) external returns (uint256 netAmountOut) {
        require(block.timestamp <= deadline,"expired");
        kat.transferFrom(msg.sender,address(this),amountIn);
        netAmountOut = amountIn * 2;
        require(netAmountOut >= minAmountOut,"min");
        vbUsdc.mint(recipient,netAmountOut);
    }
}

contract YearnMorphoMarketChildTest_v1 is Test {
    MockRewardAssetChildV1 usdc;
    MockRewardAssetChildV1 kat;
    MockMorphoDirectMarketV1 morpho;
    MockRouterChildV1 router;
    MockMerklChildV1 merkl;
    YearnMorphoMarketChild_v1 child;
    uint256 constant UNIT = 1e18;

    function setUp() public {
        vm.warp(1000);
        TokenizedStrategy impl = new TokenizedStrategy(address(0));
        // Consume Foundry's deterministic second CREATE used as Yearn fixture.
        new MockRewardAssetChildV1("Throwaway", "T");
        usdc = new MockRewardAssetChildV1("vbUSDC", "vbUSDC");
        kat = new MockRewardAssetChildV1("KAT","KAT");
        vm.etch(0x2e234DAe75C793f67A35089C9d99245E1C58470b, address(impl).code);
        morpho = new MockMorphoDirectMarketV1(address(usdc));
        router = new MockRouterChildV1(address(kat),address(usdc));
        merkl = new MockMerklChildV1(address(kat));

        child = new YearnMorphoMarketChild_v1(
            address(usdc), "One-Market Yearn Child", address(morpho), morpho.marketId(),
            address(this), address(kat), address(router), address(merkl)
        );
        ITokenizedStrategy(address(child)).setPerformanceFee(0);
        ITokenizedStrategy(address(child)).setProfitMaxUnlockTime(0);
        usdc.mint(address(this), 1000 * UNIT);
        usdc.approve(address(child), type(uint256).max);
        ITokenizedStrategy(address(child)).deposit(1000 * UNIT,address(this));
    }

    function testDepositsDirectlyIntoOneMorphoMarket() public {
        assertEq(usdc.balanceOf(address(child)), 0);
        assertEq(morpho.supplyShares(morpho.marketId(),address(child)), 1000 * UNIT);
        assertEq(child.suppliedAssets(), 1000 * UNIT);
    }

    function testInterestRecognizedOnlyAtYearnReport() public {
        morpho.accrueMockInterest(100 * UNIT);
        uint256 beforePps = ITokenizedStrategy(address(child)).pricePerShare();
        assertEq(beforePps, UNIT, "unreported interest stays out of PPS");
        ITokenizedStrategy(address(child)).report();
        assertEq(ITokenizedStrategy(address(child)).pricePerShare(), 11 * UNIT / 10);
    }

    function testMerklClaimSwapCompoundAndReport() public {
        address[] memory users = new address[](1);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        users[0] = address(child);
        tokens[0] = address(kat);
        amounts[0] = 10 * UNIT;
        proofs[0] = new bytes32[](0);

        uint256 beforePps = ITokenizedStrategy(address(child)).pricePerShare();
        uint256 received = child.claimAndCompound(users, tokens, amounts, proofs, 19 * UNIT, block.timestamp + 10);
        assertEq(received, 20 * UNIT);
        assertEq(kat.balanceOf(address(child)), 0);
        assertEq(usdc.balanceOf(address(child)), 0, "swept into direct Morpho");
        assertEq(child.suppliedAssets(), 1020 * UNIT);
        ITokenizedStrategy(address(child)).report();
        assertGt(ITokenizedStrategy(address(child)).pricePerShare(), beforePps);
    }

    function testCannotClaimForArbitraryRecipients() public {
        address[] memory users = new address[](1);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        users[0] = address(this); // not the strategy
        tokens[0] = address(kat);
        amounts[0] = 10 * UNIT;
        proofs[0] = new bytes32[](0);
        vm.expectRevert(YearnMorphoMarketChild_v1.BadClaim.selector);
        child.claimAndCompound(users,tokens,amounts,proofs,10 * UNIT,block.timestamp + 10);
    }

    function testAvailableWithdrawalLimitedByMorphoLiquidity() public {
        morpho.simulateBorrow(400 * UNIT);
        assertEq(child.availableWithdrawLimit(address(this)), 600 * UNIT);
    }
}
