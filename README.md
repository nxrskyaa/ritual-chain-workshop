# Privacy-Preserving AI Bounty Judge — Commit-Reveal

Homework solution for the **AI Bounty Judge** workshop. It extends the workshop
app so that **submissions stay hidden until judging is complete**, removing the
unfair "read earlier answers, copy the good ideas, submit an improved version"
attack.

- **Required track (implemented + tested):** commit-reveal bounty contract,
  works on any EVM chain. `contracts/CommitRevealAIJudge.sol`.
- **Advanced track (design + code hooks):** Ritual-native encrypted submissions
  judged inside a TEE. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## The problem

The workshop `AIJudge.sol` stores the plaintext answer on-chain the moment a
participant calls `submitAnswer`:

```solidity
bounty.submissions.push(Submission({submitter: msg.sender, answer: answer}));
```

Anyone can read it immediately. Later participants copy the strongest idea and
submit a better version. In a winner-take-all bounty that's unfair.

## The fix: commit-reveal

Split the lifecycle into two phases. During submission, participants publish
**only a hash** of their answer. The plaintext is revealed later, after the
submission window closes, and verified against the hash.

```
createBounty
   │   owner sets reward + submissionDeadline + revealDeadline
   ▼
submitCommitment(bountyId, commitment)        ← submission phase
   │   commitment = keccak256(answer, salt, msg.sender, bountyId)
   │   only the HASH is on-chain; answers are hidden
   ▼
── submissionDeadline ──────────────────────────────────────
   ▼
revealAnswer(bountyId, answer, salt)          ← reveal phase
   │   contract recomputes the hash and checks it matches
   │   only valid reveals become eligible for judging
   ▼
── revealDeadline ──────────────────────────────────────────
   ▼
judgeAll(bountyId, llmInput)                   ← owner only
   │   ALL revealed answers judged together in ONE Ritual LLM call
   ▼
finalizeWinner(bountyId, winnerIndex)         ← owner only, human-in-the-loop
       pays the reward to the chosen revealed submitter
```

### Why `msg.sender` and `bountyId` are in the hash

```solidity
bytes32 commitment = keccak256(
    abi.encodePacked(answer, salt, msg.sender, bountyId)
);
```

The commitment is public in the mempool/chain. If it were just
`keccak256(answer, salt)`, a front-runner could copy your commitment, then at
reveal time replay your `answer + salt` and steal authorship. Binding
`msg.sender` means a stolen commitment can only be revealed by the original
committer — anyone else recomputes a different hash and the contract rejects it
(`CommitmentMismatch`). Binding `bountyId` stops cross-bounty replay. This is
covered by the `test_Reveal_RevertStolenCommitment` test.

---

## Required Solidity functions

All four required signatures are implemented exactly:

```solidity
function submitCommitment(uint256 bountyId, bytes32 commitment) external;
function revealAnswer(uint256 bountyId, string calldata answer, bytes32 salt) external;
function judgeAll(uint256 bountyId, bytes calldata llmInput) external;
function finalizeWinner(uint256 bountyId, uint256 winnerIndex) external;
```

## Contract rules enforced

| Rule | Enforcement |
|---|---|
| Commit only before submission deadline | `block.timestamp >= submissionDeadline → SubmissionsClosed` |
| Reveal only between submission & reveal deadline | `RevealNotOpen` / `RevealClosed` |
| One commitment per address per bounty | `hasCommitted` mapping → `AlreadyCommitted` |
| Reveal valid only if hash matches | `keccak256(...) != commitment → CommitmentMismatch` |
| Unrevealed submissions not eligible | filtered off-chain + `WinnerNotRevealed` on finalize |
| Owner can judge only after reveal deadline | `RevealPhaseNotOver` |
| Owner can finalize only after judging | `NotJudgedYet` |
| One winner gets the reward | reward zeroed before transfer |

## Safety properties

- **Access control:** `judgeAll` / `finalizeWinner` are `onlyOwner(bountyId)`.
- **Reentrancy:** `finalizeWinner` follows checks-effects-interactions —
  `finalized = true` and `reward = 0` are set *before* the external call.
- **No auto-pay from AI output:** the AI review is advisory. The human owner
  reads the recommendation and explicitly calls `finalizeWinner`. The off-chain
  `parseAiReview` helper validates that the recommended `winnerIndex` is a
  revealed submission before the owner acts.
- **Batch judging:** `judgeAll` makes a single LLM precompile call for all
  revealed answers — never one call per submission.

---

## Project layout

```
hardhat/
  contracts/
    CommitRevealAIJudge.sol      ← the homework contract (required track)
    AIJudge.sol                  ← original workshop contract (reference)
    utils/PrecompileConsumer.sol ← Ritual precompile addresses + decode helper
  test/
    CommitRevealAIJudge.t.sol    ← 22 tests, forge-std (Solidity)
  scripts/
    commitReveal.ts              ← off-chain commitment + batch-input helpers
  hardhat.config.ts              ← viaIR + optimizer enabled (stack-too-deep fix)
docs/
  ARCHITECTURE.md                ← commit-reveal vs Ritual-native + reflection
```

## Build & test

```bash
cd hardhat
pnpm install
npx hardhat compile
npx hardhat test solidity
```

Expected: `22 passing` (21 unit/integration + 1 fuzz @ 256 runs).

> Note: `viaIR: true` + optimizer are enabled in `hardhat.config.ts`. The
> `getBounty` view returns 12 values and trips "stack too deep" on the legacy
> codegen path; `viaIR` resolves it.

---

## Test plan — valid and invalid reveal cases

The suite (`test/CommitRevealAIJudge.t.sol`) covers every state transition and
the security-critical edges. Highlights:

**Happy path**
- `test_FullLifecycle_HappyPath` — create → 2 commits → assert answers hidden →
  reveal both → judge → finalize → winner paid, reward zeroed.

**Commit phase (invalid)**
- after submission deadline → `SubmissionsClosed`
- second commit by same address → `AlreadyCommitted`
- unknown bounty → `BountyNotFound`

**Reveal phase (invalid)**
- before submission deadline → `RevealNotOpen`
- after reveal deadline → `RevealClosed`
- wrong answer → `CommitmentMismatch`
- wrong salt → `CommitmentMismatch`
- **stolen commitment** (front-runner) → `CommitmentMismatch`
- no prior commitment → `NothingToReveal`
- double reveal → `AlreadyRevealed`

**Judge (invalid)**
- before reveal deadline → `RevealPhaseNotOver`
- non-owner caller → `NotBountyOwner`
- zero revealed answers → `NoRevealedAnswers`
- double judge → `AlreadyJudged`

**Finalize (invalid)**
- before judging → `NotJudgedYet`
- winner never revealed → `WinnerNotRevealed`
- out-of-range index → `InvalidWinnerIndex`
- double finalize → `AlreadyFinalized`

**Create (invalid)**
- zero reward → `RewardRequired`
- mis-ordered deadlines → `BadDeadlines`

**Fuzz**
- `testFuzz_RevealMatchesCommitment(string,bytes32)` — for any answer/salt, a
  commitment built off the same formula always reveals successfully (256 runs).

---

## Off-chain helpers (`scripts/commitReveal.ts`)

- `prepareCommitment(bountyId, submitter, answer)` → generates a random salt and
  the matching commitment; returns the secret bundle to persist client-side.
- `computeCommitment(...)` → mirrors the on-chain hash exactly (viem
  `encodePacked` of `string,bytes32,address,uint256`).
- `buildBatchJudgeInput(...)` → filters to revealed answers and shapes the
  single batch payload for the LLM (pairs with the workshop's
  `buildJudgeAllLlmInput`).
- `parseAiReview(...)` → validates the AI recommendation and that the proposed
  winner is a revealed submission, **before** the owner finalizes.
