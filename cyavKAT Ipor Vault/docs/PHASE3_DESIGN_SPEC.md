# Phase 3 design spec: governance (#6, #7, #8)

Status: **APPROVED 2026-09-25** · build is local only (Option C)

> **HARD RULE: the Aragon Admin plugin is never removed or revoked by any Phase 3 script.** It is not part of the initial deploy or config sequence. It is removed later, only when you explicitly ask.

## 0. Goal
Governance of the cyavKAT system moves to an Aragon DAO on Katana.
- **Voting:** cyavKAT lockers vote, and can delegate their votes.
- **Proposals:** a 2-of-3 Safe creates them. The two bot keys are held on separate infrastructure (GitHub and Cloudflare).
- **Requests:** anyone can request a parameter change by paying a fixed cyavKAT bond.
- **Engagement tokens:** proposers, voters and delegators on passed proposals earn engagement tokens (non-transferable, decaying), which receive forwarded reward tokens.
- **Guardian:** a bounded Optimization Guardian contract handles day-to-day tuning and emergency pause.

Checked: cyavKAT is transferable.
- **Aragon OSx v1.4 on Katana:** DAOFactory `0xd59D…D835`, TokenVoting repo `0xBAFF…0E5b` (v1.4), Admin repo `0x95d1…DAeC`.
- **Safe v1.4.1:** proxy factory `0x4e1D…0ec67`.
- Full list: research/ARAGON_KATANA_ADDRESSES.md.
- **Clock:** TokenVoting v1.4 supports ERC-6372 timestamp clocks, so the lock checkpoints by `block.timestamp`.

## 1. Contracts

### 1.1 CurveYieldVotingLock (#7): the DAO's voting token (IVotes)
- `lock` / `unlock` cyavKAT at any time. Voting power ramps linearly to full over **60 days** (the range is 0–180 days).
- Adding to a lock moves its start to the amount-weighted average: `(a·s + x·now)/(a+x)`.
- **Delegation allowed (D-G1):** `delegate(to)` moves the account's ramped power to `to`.
  - Checkpoints `getPastVotes` / `getPastTotalSupply` follow the OpenZeppelin `Votes` pattern.
  - The lock stores who each delegator delegated to at each checkpoint (`delegateOf(account, t)`). Rewards (§1.6) need this.
- Total supply for quorum = total locked (not ramped). The lock is non-transferable, and locked cyavKAT keeps earning vault yield.

### 1.2 Aragon DAO: TokenVoting + Admin plugin
- A new DAO through the Katana DAOFactory with **two plugins**:
  - **TokenVoting** on the voting lock:
    - **support 66%**, **minimum participation 10%**, **voting period 7 days** (D-G2/D-G3), early execution off;
    - proposal creation: **only the Safe**.
  - **Admin plugin:** admins are the deployer and `0x9f2B…E288` (the same pattern as the DEX). It **stays in place** (hard rule above).
- The DAO is the owner of record for everything in §2. The Admin plugin lets post-deploy configuration go through without a 7-day vote.

### 1.3 Gnosis Safe 2-of-3 (#6)
- **Owners:**
  - you;
  - **bot 1**, proposal intake, running on **GitHub Actions**;
  - **bot 2**, the safety checker, running on a **Cloudflare Worker**, with its key in Cloudflare secrets.
- Threshold 2. **A GitHub leak exposes only 1 of 3 keys, and a Cloudflare leak exposes only 1.** Neither alone controls the Safe.

### 1.4 CurveYieldProposalBond (#6)
- **Parameter registry (DAO-owned):** `paramId → (target, setter selector, min, max)`.
- **Bond (D-G9):** a single fixed fee, `bondAmount`, **default 200 cyavKAT**, set by the DAO; it is not a range.
- `request(paramId, value)`: the value must be in `[min, max]`; the bond is pulled in; emits `ProposalRequested`.
- Bot 1 builds the proposal; bot 2 (Cloudflare) checks it and co-signs; the Safe creates it; `linkProposal` records the Aragon id.
- `settle(requestId)`, callable by anyone:
  - **passed and executed:** the bond is refunded and the proposer gets `proposerReward` engagement tokens (§1.6);
  - **failed:** the bond is slashed;
  - **rejected:** the Safe (2 of 3) executes `bond.reject(requestId)` on-chain. The bond is **slashed** (D-G5).
  - **neither proposed nor rejected within `intakeWindow` (7 days):** the bond is refunded. This only happens when the bots are down.
- **Slash split (D-G5):** one third each (33.33%) to:
  - the admin-fee receiver (the fee Safe);
  - the contributors reward sink;
  - the engagement-reward pool.
  - Rounding dust goes to the engagement pool. Slashed cyavKAT is paid out as cyavKAT.

### 1.5 Safety-check bot (bot 2): Cloudflare Worker
- Cron-triggered Worker. It reads pending Safe transactions from the Safe Transaction Service and checks each call against the on-chain parameter registry plus a static (target, selector) allowlist.
- It co-signs only if every call is in range; otherwise it proposes a Safe rejection and emits an alert.
- Its key lives only in Cloudflare secrets.
- Sonnet builds it from my spec; the deploy chain is the one we already use for the dapp.

### 1.6 CurveYieldEngagementToken (#8)
- **Holdings:** non-transferable **lots** `{amount, decayed, slowUntil50, slowUntil75}`, **capped at 64 per holder**; the oldest lots merge when the cap is hit.
- **Decay:** linear to zero over 6 months of decay time.
  - A lot slowed once decays at half speed.
  - A lot slowed twice decays at quarter speed (a 75% slow).
- **Slowing:** each new unit earned slows 2 existing units for 4 months, **oldest first (D-G6)**.
- **Earning (D-G4/D-G7):** all amounts are set by the DAO and bounded.
  - **Proposer:** `proposerReward`, range 0–1,000, **default 100**, paid at `settle`.
  - **Voters:** each passed proposal has a voter pool, `voterPool`, range 0–1,000, **default 100**.
    - Each vote's share = its voting power ÷ total voting power cast on that proposal.
    - It is claimed with `claimVoterReward(proposalId)`.
  - **Delegators** get a share of the part of the vote that came from their delegated power, minus a **haircut**, `delegatorHaircutBps`, **default 50%**.
  - **Delegatees** get their own-power share, plus **`delegateeCutBps` of the haircut (default 20%)**. The other 80% of the haircut is not minted.
  - Example: a delegator whose power earned 10 units gets 5; the delegatee gets 1 of the 5 cut; 4 are not minted.
  - Each delegator claims their own reward, `claimDelegatorReward(proposalId)`. Their power and delegatee come from the lock's checkpoint at the proposal's snapshot, and they are paid only if that delegatee voted.

### 1.7 CurveYieldEngagementRewards (#8)
- A DAO-whitelisted list of reward tokens.
- Payouts run in epochs:
  1. `distribute(token)` snapshots the holders' decayed balances, 500 per call.
  2. Holders `claim(epoch)` their pro-rata share.
- It receives 33% of slashed bonds, plus any reward tokens forwarded to it.

### 1.8 CurveYieldOptimizationGuardian (D-G8)
A dedicated contract; no bot or deployer key touches the vault or controllers directly.
- **Owners, any one of which can act as owner:**
  - the deployer wallet;
  - the fee-receiving Safe;
  - the Aragon DAO.
- **Owners can:** set or remove the bot operator; set the bot ranges within the DAO registry ranges; pause and unpause the vault; call every bot function.
- **Bot operator** (the #17 maintenance bot's key) can, only within the guardian's ranges:
  - change **all allocation caps**: loop, vKAT, lend, LP and the vault floor, via the Allocation / Lend / LP controller setters;
  - **deploy and rebalance the yield-boosting custody**: the Vault Growth Custody `0xe7D1` wind-up and rebalance, through its existing fuse path;
  - the #17 tuning setters: vKAT allocation and the Morpho cap decay;
  - **emergency pause**.
- **Vault emergency pause:** the guardian holds IPOR **GUARDIAN_ROLE (2)** and calls `accessManager.updateTargetClosed(vault, true/false)`.
  - The bot may only **pause**. **Unpausing** is owners only.
- Controllers and custody grant the guardian a dedicated `guardian` permission rather than ownership.

### 1.9 CurveYieldGovernanceGate: the DAO's only handle on the system (approved 2026-09-25)
The DAO never owns contracts directly. The gate is the owner of record of every CurveYield contract and holds the vault's IPOR roles.
- **DAO path:** `execute(target, data)`, callable by the DAO only. It forwards the call unless the call is **protected**.
- **Protected calls:** only holders of the `FEE_AUTHORITY` role can make them.
  - every admin-fee setter, covering both receivers and percentages:
    - the vault's IPOR fee settings (performance and management fee, and their recipients);
    - the loop profit splitter's yield-boosting share and Growth Custody destination, plus any admin share;
    - wcyavKAT `setFees`;
    - the wrapper fee splitter's `setAdminReceiver`;
    - any future admin fee;
  - ownership moves on gated contracts (`transferOwnership`, `renounceOwnership`), so nothing can leave the gate;
  - IPOR access-manager role grants and revokes that touch a fee role.
- **The `FEE_AUTHORITY` role:**
  - The initial holder is the fee Safe `0x4762…`.
  - Holders can grant or revoke it; no one else can, including the DAO through any proposal.
  - Only `FEE_AUTHORITY` can edit the protected-call list.
- **Why an intermediary:** the protection doesn't depend on who is allowed to propose. It stays intact if proposals are opened to others later.
- The final handover check lists the Safe's `FEE_AUTHORITY` and the Aragon Admin plugin as the only allowed exceptions.

## 2. Handover (#6): everything non-public goes to the DAO
This is built from Sonnet's controls inventory. **Nothing in it touches the Admin plugin.**
1. Ownership of every Phase 2/3 contract passes to the DAO (Ownable2Step). The DAO accepts through **Admin-plugin `executeProposal`**. This covers:
   - the controllers, executor, splitter, the vKAT / lend / LP contracts, the lock, the bond, the engagement contracts and the guardian;
   - the router `0x01F9` and custody `0xe7D1`, via Safe transactions.
2. IPOR access manager:
   - grant OWNER / ATOMIST / FUSE_MANAGER / 900 / 1200 to the DAO, and GUARDIAN (2) to the guardian;
   - revoke those roles from the deployer;
   - operational roles stay on the contracts.
3. The guardian is deployed with owners {deployer, fee Safe, DAO} and the bot operator set.
4. **Final check script:**
   - the deployer holds **no IPOR role and owns no contract**;
   - the **allowed exceptions**, listed explicitly, are the guardian co-ownership and the Aragon Admin-plugin admin.

## 3. Build order
1. Voting lock with delegation checkpoints, plus tests (Sonnet writes the tests).
2. Engagement token + rewards + tests.
3. Proposal bond + registry + tests.
4. Optimization guardian + tests.
5. DAO / TokenVoting / Admin plugin / Safe deploy scripts, plus a fork test.
6. Controls inventory → handover scripts → fork test of the full handover. It asserts that the Admin plugin is still installed.
7. Bots:
   - bot 1 on GitHub Actions and bot 2 on a Cloudflare Worker (Sonnet, from my spec);
   - the #17 bot now calls the guardian.

## 4. Decisions (answered)
| # | Decision |
|---|---|
| D-G1 | Delegation allowed |
| D-G2/3 | Support 66%, minimum participation 10%, voting period 7 days |
| D-G4 | Rewards in engagement tokens: proposer 0–1,000 (default 100); voters pro-rata by power; delegator haircut 50%; delegatee gets 20% of that haircut; all DAO-configurable |
| D-G5 | Slash split ⅓ / ⅓ / ⅓ (fee receiver / contributors / engagement pool); a Safe-executed rejection slashes; a timeout refunds |
| D-G6 | Oldest first; 64-lot cap |
| D-G7 | Amounts configurable, default 100 |
| D-G8 | Optimization Guardian contract: owners are the deployer, fee Safe and DAO; it controls allocation caps, custody deploy/rebalance and vault pause |
| D-G9 | Fixed bond fee, default 200 cyavKAT |
| D-G10 | Aragon on Katana: no fallback needed. **Admin plugin kept until you explicitly ask.** |

## 5. Open points
None. The spec was approved on 2026-09-25:
- the slash split is ⅓ / ⅓ / ⅓;
- only an on-chain rejection executed by the Safe slashes a bond; a timeout refunds it.
