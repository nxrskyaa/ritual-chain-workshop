/**
 * ============================================================================
 *  Commit-reveal helpers for the Privacy-Preserving AI Bounty Judge
 * ============================================================================
 *
 * Off-chain glue used by the frontend / scripts. Two responsibilities:
 *
 *   1. REQUIRED TRACK  — compute commitments client-side and build the batch
 *      `llmInput` from ONLY the revealed answers (one LLM call, not one per
 *      submission).
 *
 *   2. ADVANCED TRACK  — sketch of the Ritual-native encrypted-submission flow
 *      (ECIES encrypt to the TEE executor, batch decrypt + judge inside the
 *      enclave). See docs/ARCHITECTURE.md for the full design.
 *
 * The commitment MUST match the on-chain check exactly:
 *   keccak256(abi.encodePacked(answer, salt, submitter, bountyId))
 */

import {
  encodePacked,
  keccak256,
  toHex,
  type Address,
  type Hex,
} from "viem";

// ---------------------------------------------------------------------------
// 1) REQUIRED TRACK: commitment computation
// ---------------------------------------------------------------------------

/**
 * Compute the commitment exactly the way CommitRevealAIJudge verifies it.
 * `abi.encodePacked(string, bytes32, address, uint256)` in Solidity ==
 * encodePacked(["string","bytes32","address","uint256"], [...]) in viem.
 */
export function computeCommitment(params: {
  answer: string;
  salt: Hex; // 32-byte salt
  submitter: Address;
  bountyId: bigint;
}): Hex {
  const { answer, salt, submitter, bountyId } = params;
  return keccak256(
    encodePacked(
      ["string", "bytes32", "address", "uint256"],
      [answer, salt, submitter, bountyId],
    ),
  );
}

/** Cryptographically-random 32-byte salt. KEEP IT SECRET until reveal. */
export function randomSalt(): Hex {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return toHex(bytes);
}

/**
 * A participant's local secret bundle. The salt and answer never go on-chain
 * during the submission phase — only `commitment` does. Persist this client-side
 * (localStorage / download) so the participant can reveal later.
 */
export type CommitSecret = {
  bountyId: string;
  submitter: Address;
  answer: string;
  salt: Hex;
  commitment: Hex;
};

export function prepareCommitment(
  bountyId: bigint,
  submitter: Address,
  answer: string,
): CommitSecret {
  const salt = randomSalt();
  const commitment = computeCommitment({ answer, salt, submitter, bountyId });
  return {
    bountyId: bountyId.toString(),
    submitter,
    answer,
    salt,
    commitment,
  };
}

// ---------------------------------------------------------------------------
// 2) REQUIRED TRACK: build the batch llmInput from REVEALED answers only
// ---------------------------------------------------------------------------

export type RevealedSubmission = {
  index: number;
  submitter: Address;
  answer: string;
  revealed: boolean;
};

/**
 * Build the judging payload from on-chain submissions. CRITICAL: filter to
 * `revealed === true`. Unrevealed entries have an empty answer on-chain and are
 * not eligible — the contract enforces this too, but we never even send them to
 * the model. The whole set is judged in ONE request (batch judging), never one
 * LLM call per answer.
 *
 * The actual ABI encoding for the Ritual LLM precompile is delegated to the
 * workshop's `buildJudgeAllLlmInput` (web/src/lib/ritualLlm.ts). This function
 * is the pre-step that guarantees only revealed answers reach it.
 */
export function buildBatchJudgeInput(args: {
  title: string;
  rubric: string;
  submissions: RevealedSubmission[];
}): {
  title: string;
  rubric: string;
  judged: { index: number; submitter: string; answer: string }[];
} {
  const judged = args.submissions
    .filter((s) => s.revealed && s.answer.length > 0)
    .map((s) => ({
      index: s.index,
      submitter: s.submitter,
      answer: s.answer,
    }));

  if (judged.length === 0) {
    throw new Error("No revealed answers to judge.");
  }

  return { title: args.title, rubric: args.rubric, judged };
}

/**
 * Parse + validate the AI review bytes returned by judgeAll / stored in
 * `bounty.aiReview`. We DO NOT auto-pay from this. The owner reads the
 * recommendation, sanity-checks that `winnerIndex` refers to a revealed
 * submission, and then calls finalizeWinner manually (human-in-the-loop).
 */
export type AiReview = {
  winnerIndex: number;
  ranking?: { index: number; score: number; reason: string }[];
  revealedAnswersRef?: string;
  revealedAnswersHash?: Hex;
  summary: string;
};

export function parseAiReview(
  reviewBytesUtf8: string,
  revealedIndices: number[],
): { ok: true; review: AiReview } | { ok: false; error: string } {
  let parsed: AiReview;
  try {
    parsed = JSON.parse(reviewBytesUtf8) as AiReview;
  } catch {
    return { ok: false, error: "AI review is not valid JSON" };
  }
  if (typeof parsed.winnerIndex !== "number") {
    return { ok: false, error: "winnerIndex missing or not a number" };
  }
  // The recommended winner MUST be one of the revealed (eligible) submissions.
  if (!revealedIndices.includes(parsed.winnerIndex)) {
    return {
      ok: false,
      error: `winnerIndex ${parsed.winnerIndex} is not a revealed submission`,
    };
  }
  return { ok: true, review: parsed };
}

// ---------------------------------------------------------------------------
// 3) ADVANCED TRACK (design sketch): Ritual-native encrypted submissions
// ---------------------------------------------------------------------------
//
// In the commit-reveal flow, answers become PUBLIC at reveal time, before the
// human owner has finalized. The Ritual-native flow keeps plaintext hidden the
// whole way: participants encrypt to the TEE executor; only the enclave ever
// sees plaintext; the chain stores ciphertext + hashes. See ARCHITECTURE.md.
//
// The code below is illustrative — it shows where ECIES encryption hooks in.
// Run against a live executor public key fetched from TEEServiceRegistry.
//
//   import { encrypt, ECIES_CONFIG } from "eciesjs";
//   ECIES_CONFIG.symmetricNonceLength = 12; // MANDATORY for Ritual
//
//   export function encryptAnswerForExecutor(
//     answer: string,
//     executorPublicKey: Hex, // from TEEServiceRegistry.getServicesByCapability
//   ): Hex {
//     const buf = encrypt(executorPublicKey.slice(2), Buffer.from(answer, "utf-8"));
//     return `0x${buf.toString("hex")}`;
//   }
//
// On-chain the contract stores `encryptedAnswer` (or an off-chain storage ref +
// keccak256 hash). During judgeAll, the executor decrypts every submission
// inside the enclave, judges them as one batch, and emits:
//   { winnerIndex, ranking, revealedAnswersRef, revealedAnswersHash, summary }
// The owner verifies revealedAnswersHash against the published bundle, then
// finalizes.
