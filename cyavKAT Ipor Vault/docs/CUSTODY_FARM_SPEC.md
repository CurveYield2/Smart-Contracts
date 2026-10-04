# Revenue custody v2 + custody farm — spec, APPROVED 2026-09-29 (new funds follow current proportions; farm
# rebalancing between positions stays manual)

Extends PPS_PROTECTION_SPEC B5 (revenue custody v2 as the emergency backstop). User requirements, 2026-09-29.

## 1. Two allocations
1. **Morpho loop** — the existing automatic avKAT collateral / KAT debt loop in `CurveYieldRevenueCustodyV2`.
2. **Farm ("everything else")** — deployed and redeployed by hand by the owner or an operator, in a new contract
   `CurveYieldCustodyFarm` (custody v2 is already 15.2 KB; the farm cannot fit in it).
- **Target:** gate key `custody.loopTargetBps` (DAO class, hard range **30–80%**, **default 60%**; user 2026-09-29) = loop equity as a share of
  the custody's total value (idle + loop equity + farm value).
- **`deployAll()` (operators):** spare avKAT first tops the loop up to target; the **remainder is spread over the
  farm's active positions** (those holding value) **in proportion to each one's current value** — per position:
  swap avKAT into its two tokens in the ratio it currently holds (Charm: `getTotalAmounts`; Sushi V3: its tick range at
  the current price) through router v2 (protected minimum), then add liquidity (Charm `deposit` / Sushi
  `increaseLiquidity` — a staked NFT is first unstaked from `SushiStaker`, topped up, then restaked; user 2026-09-29), minimums from the protected quotes. Dust stays idle in the farm;
  with no active positions the remainder stays idle. No automatic reduction of the loop when it is above target.

## 2. Farm contract `CurveYieldCustodyFarm`
- Holds the farm's tokens, Sushi V3 NFTs and Charm shares. Owner = the custody's owner (the gate after handover).
- **Operators:** your wallet `0x9f2B…E288`, the fee Safe `0x4762…3C49` and the deployer `0x11b7…FA35` (user
  2026-09-29). `setOperator` is fee-authority-only (protected), as operators move funds.
- **Allowlists (fee-authority-only):**
  - Sushi V3 pools (the pool address; its two tokens become allowed tokens);
  - Charm vaults (the vault address; its two tokens become allowed tokens); starting with vbWBTC-vbUSDC
    `0xBC2A…90ff` (the only incentivised WBTC/USDC Charm vault on Katana today — note: ~$2.4k TVL);
  - the Sushi NFT staker `0xbe12…29E9` (`SushiStaker`);
  - Merkl distributor `0x3Ef3…Ae9Ae`.
  - avKAT and KAT are always allowed tokens.
- **Actions (operators):**
  - `pull(amountAvkat)` from the custody's idle avKAT into the farm (custody-side function, operator only), and
    `push(amountAvkat)` back.
  - `swap(tokenIn, tokenOut, amountIn, minOut)` through the swap router v2 (protected minimum, 0.1% fee); both tokens
    must be allowed tokens. Every allowed token needs a router v2 route to and from avKAT.
  - Sushi V3 (NonfungiblePositionManager): `mint` (allowlisted pool, ticks, amounts, mins), `increaseLiquidity`,
    `decreaseLiquidity`, `collect`, `burn`.
  - `stake(tokenId)` / `unstake(tokenId)` on `SushiStaker`. **While staked, the position's trading fees go to Sushi's
    fee collector, not to the farm** — staking trades fees for KAT incentives.
  - Charm: `deposit(amount0, amount1, min0, min1)` / `withdraw(shares, min0, min1)` on allowlisted vaults.
  - `harvest(tokens, amounts, proofs)`: Merkl claim into the farm → each claimed token swapped to avKAT through router
    v2 → split exactly like a loop gain: `custody.rewardManagerBps` to the rewards claim manager (then
    `updateBalance`), `custody.feeRecipientBps` to the custody's fee recipient, the rest stays (farm idle).
- **Valuation** `totalValueAvkat()`: idle tokens + Sushi V3 positions (amounts at the pool's TWAP price, plus owed fees)
  + Charm shares (`getTotalAmounts` × share) — each token valued in avKAT with router v2's protected quote.
- **Backstop pull** `coverPull(amountAvkat)` (custody only): unwinds farm holdings in this order until the amount is
  reached — idle avKAT, other idle tokens (swapped), Charm withdrawals, Sushi V3 positions (unstake if staked,
  decrease liquidity, collect, swap) — and sends the avKAT to the custody. Each step uses router v2's protected
  minimum; a step that fails is skipped.

- **Size:** the farm splits into `CurveYieldCustodyFarm` (holds and executes) and a view-only
  `CurveYieldCustodyFarmPlanner` (valuation, proportional sizing, token ratios, minimums) if it does not fit 24 KB.

## 3. Custody v2 changes
- `cover(loss)` order: **idle avKAT → farm `coverPull` → loop flash unwind** (today: idle → loop).
- `setFarm(farm)` (fee-authority-only); `loopTargetBps` read from the gate; `deployAll()` honours the target.
- Everything else unchanged (loop, wind-up split, full unwind, coverer = executor only).

## 4. Migration (P6) — unchanged in shape
P6_01: deploy custody v2 + farm, wire coverer / backstop / references, hand both to the gate, fee Safe schedules the
live custody's full unwind to v2. P6_02 (after 15 days): execute the full unwind; `deployAll` fills the loop to 60%.

## 5. Decisions
- **C1** ~~Operators~~ — decided: your wallet, the fee Safe, the deployer.
- **C2** ~~Charm starting vault~~ — decided: vbWBTC-vbUSDC `0xBC2A…90ff`.
- **C3** ~~Farm auto-deploy~~ — decided: `deployAll` spreads the post-loop remainder pro rata over active positions.
