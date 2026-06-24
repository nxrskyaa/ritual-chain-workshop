# Architecture Note: Commit-Reveal vs Ritual-Native Encrypted Submissions

Two ways to hide bounty answers until judging. The required track ships the
first; the advanced track designs the second.

---

## 1. Commit-Reveal (Required Track — implemented)

### What's on-chain vs hidden

| Phase | On-chain | Hidden |
|---|---|---|
| Submission | `commitment = keccak256(answer, salt, sender, bountyId)` | answer, salt |
| Reveal | answer, salt (now public), `revealed = true` | — |
| Judge | `aiReview` bytes from the LLM | — |
| Finalize | `winnerIndex`, payout | — |

### Flow

```
Participant A                 Contract                     Owner / Ritual LLM
─────────────                 ────────                     ──────────────────
answer + random salt
  │  keccak256(answer,salt,A,id)
  ▼
submitCommitment(id, hash) ─► store hash only
                              (answer NOT on chain)
        ... submission deadline passes ...
revealAnswer(id, answer, salt)
  │                         ─► recompute hash, must match
  │                            store answer, revealed=true
        ... reveal deadline passes ...
                                                         judgeAll(id, llmInput)
                              run LLM on ALL revealed ◄──── (owner)
                              answers in ONE batch call
                              store aiReview
                                                         finalizeWinner(id, k)
                              pay reward to revealed  ◄──── (owner, human pick)
                              submitter k
```

### Strengths
- Works on **any EVM chain**. No special infrastructure.
- Simple to reason about and cheap to verify (`keccak256` + timestamps).
- Strong against the copy-an-earlier-answer attack during submission.

### The one limitation
Answers become **public at reveal time**, which is *before* the owner finalizes
and arguably before everyone has been judged in practice. Anyone watching the
chain sees every revealed answer. For most bounties that's acceptable (judging
is about to happen anyway), but the plaintext is no longer private once revealed.
That's exactly the gap the Ritual-native track closes.

---

## 2. Ritual-Native Encrypted Submissions (Advanced Track — design)

Goal: plaintext answers are **never public on the base chain**. Only the TEE
executor (inside its enclave) ever sees them, and only during judging.

### Where the plaintext lives, and who can read it

| Artifact | Location | Who can read |
|---|---|---|
| Plaintext answer | participant's browser, then ECIES ciphertext | author only; executor inside enclave at judge time |
| Encrypted answer (ciphertext) | on-chain **or** off-chain blob + on-chain hash | nobody can decrypt except the executor's enclave key |
| Decrypted answers (batch) | TEE executor memory during `judgeAll` | the enclave only; never written to public chain |
| AI ranking result | on-chain (`aiReview`) | public |
| Revealed answers bundle | off-chain (IPFS/storage), hash on-chain | public after judging |

### What is stored on-chain vs off-chain

- **On-chain:** `encryptedAnswer` references (or hashes), bounty metadata,
  `revealedAnswersHash`, `revealedAnswersRef`, final `winnerIndex`, `aiReview`.
- **Off-chain:** the actual ciphertext blobs if too large for storage (store
  only `keccak256` on-chain), and the post-judging revealed-answers bundle.

To avoid large plaintext on-chain (gas), use the suggested pattern: publish a
revealed-answers bundle off-chain and store `revealedAnswersRef` +
`revealedAnswersHash` on-chain so anyone can verify integrity.

### How the LLM receives all submissions together (batch judging)

`judgeAll` triggers a **single** Ritual LLM inference call. The executor:
1. Reads all encrypted submissions (or fetches blobs by reference).
2. Decrypts every one inside the enclave using its private key.
3. Assembles them into one prompt (a JSON array of `{index, answer}`).
4. Runs the model once, comparing all answers against the rubric.
5. Returns a single ranked result.

No `for` loop of per-answer LLM calls — one request, all submissions, as the
homework requires.

### How encryption works (ECIES to the executor)

```
Participant                         TEE Executor (enclave)
───────────                         ──────────────────────
fetch executor pubkey  ◄──── TEEServiceRegistry.getServicesByCapability()
ECIES_CONFIG.symmetricNonceLength = 12   // MANDATORY for Ritual
encrypt(answer, executorPubKey)
  │  ciphertext
  ▼
store on-chain / off-chain ref ───► (only this enclave's private key decrypts)
```

### How the final reveal happens & how the contract commits to it

After judging, the system publishes the revealed-answers bundle off-chain and
records its hash on-chain. The example final output shape:

```json
{
  "winnerIndex": 2,
  "ranking": [{ "index": 2, "score": 94, "reason": "Best satisfies the rubric." }],
  "revealedAnswersRef": "ipfs://... or storage-ref://...",
  "revealedAnswersHash": "0x...",
  "summary": "Submission 2 is the strongest answer."
}
```

The owner (and anyone) recomputes `keccak256(bundle)` and checks it equals
`revealedAnswersHash` before trusting it. Then the owner calls `finalizeWinner`.
The AI **recommends**; the human **finalizes** the payout.

### Ritual features used (beyond "just call an LLM")
- **TEE-backed execution:** judging logic sees private inputs while keeping them
  hidden from the public chain.
- **Encrypted inputs/secrets:** answers (and any storage credentials) are ECIES
  ciphertext on-chain, never plaintext.
- **Batch judging:** all submissions in one inference request.
- **Human-in-the-loop finalization:** AI ranks, owner pays.

---

## Side-by-side

| | Commit-Reveal (required) | Ritual-Native (advanced) |
|---|---|---|
| Chain | any EVM | Ritual |
| Hidden during submission | ✅ (hash only) | ✅ (ciphertext) |
| Hidden during judging | ❌ public after reveal | ✅ enclave-only |
| Plaintext ever public | yes, at reveal | only the bundle after judging |
| Infra needed | none | TEE executor + key flow |
| Trust assumption | hash-binding + timestamps | TEE attestation + executor key |
| Gas for large answers | stores plaintext on reveal | store hash/ref, blob off-chain |

---

## Reflection: what should be public, hidden, and decided by AI vs human?

In a bounty system, the **rules** should be public — the reward, the rubric, the
deadlines, who has committed, and ultimately the winner and the AI's reasoning —
because participants and observers need to trust the contest was fair and
verifiable on-chain. The **answers themselves should stay hidden during the
submission phase**, since visible answers let latecomers copy and improve on
earlier ideas, which destroys fairness in a winner-take-all setting. Commit-reveal
hides answers behind a hash until a reveal window, while a Ritual-native TEE flow
can keep them encrypted even through judging so they are never exposed to
competitors. The **AI should do the evaluation work** — reading every revealed
answer in one batch and scoring it against the rubric — because it is consistent,
fast, and impartial to who submitted what. But the **human owner should make the
final payout decision**, treating the AI output as a recommendation rather than
an automatic trigger, because models can be wrong, can be manipulated by prompt
injection inside submissions, or can misread an ambiguous rubric. That human
checkpoint is also where you validate that the recommended winner is actually a
valid, revealed submission before money moves. In short: make the process and
outcome transparent, keep the contestants' work private until judging is done,
let AI scale the judging, and keep a human accountable for the irreversible step.
