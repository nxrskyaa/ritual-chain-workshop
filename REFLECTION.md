# Reflection

**Question:** What should be public, what should stay hidden, and what should be decided by AI versus by a human in a bounty system?

*Builder: nxrskyaa — Privacy-Preserving AI Bounty Judge*

---

In a bounty system, the **rules** should be public — the reward, the rubric, the deadlines, who has committed, and ultimately the winner and the AI's reasoning — because participants and observers need to trust the contest was fair and verifiable on-chain. The **answers themselves should stay hidden during the submission phase**, since visible answers let latecomers copy and improve on earlier ideas, which destroys fairness in a winner-take-all setting. Commit-reveal hides answers behind a hash until a reveal window, while a Ritual-native TEE flow can keep them encrypted even through judging so they are never exposed to competitors. The **AI should do the evaluation work** — reading every revealed answer in one batch and scoring it against the rubric — because it is consistent, fast, and impartial to who submitted what. But the **human owner should make the final payout decision**, treating the AI output as a recommendation rather than an automatic trigger, because models can be wrong, can be manipulated by prompt injection inside submissions, or can misread an ambiguous rubric. That human checkpoint is also where you validate that the recommended winner is actually a valid, revealed submission before money moves. In short: make the process and outcome transparent, keep the contestants' work private until judging is done, let AI scale the judging, and keep a human accountable for the irreversible step.

---

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full system design (commit-reveal vs Ritual-native TEE, batch judging, and where plaintext lives).
