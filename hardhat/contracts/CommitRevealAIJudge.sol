// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
    function depositFor(address user, uint256 lockDuration) external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function lockUntil(address) external view returns (uint256);
}

/**
 * @title CommitRevealAIJudge
 * @notice Privacy-preserving AI bounty judge using a commit-reveal scheme.
 *
 *  Problem with the workshop AIJudge: `submitAnswer` stores the plaintext answer
 *  on-chain immediately, so later participants can read earlier answers, copy the
 *  good ideas, and submit an improved version. That is unfair when only one person
 *  wins.
 *
 *  Fix: participants first publish ONLY a commitment hash during the submission
 *  phase. The real answers are not on-chain yet. After the submission deadline,
 *  participants reveal their answer + salt; the contract recomputes the hash and
 *  checks it matches. Only valid reveals are eligible for AI judging. The owner
 *  then batch-judges all revealed answers in a single Ritual LLM call and
 *  finalizes one winner.
 *
 *  Lifecycle:
 *    createBounty -> submitCommitment* -> [submission deadline]
 *      -> revealAnswer* -> [reveal deadline] -> judgeAll -> finalizeWinner
 */
contract CommitRevealAIJudge is PrecompileConsumer {
    // --------------------------------------------------------------- builder
    // Builder identity, baked into the contract. BUILDER_ADDRESS is immutable
    // and set to the deployer at construction, so a copy-paste fork that
    // redeploys from a different wallet will carry a different address than the
    // one signed below — making authorship verifiable on-chain.
    string public constant BUILDER = "nxrskyaa";
    string public constant BUILDER_NOTE =
        "Built by nxrskyaa - Privacy-Preserving AI Bounty Judge homework";
    address public immutable BUILDER_ADDRESS;

    // ----------------------------------------------------------------- limits
    uint256 public constant MAX_SUBMISSIONS = 50;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    IRitualWallet public wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    // ----------------------------------------------------------------- types
    struct Submission {
        address submitter;     // who committed
        bytes32 commitment;    // keccak256(answer, salt, submitter, bountyId)
        string answer;         // empty until a valid reveal
        bool revealed;         // true once revealed & verified
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline; // commits allowed strictly before this
        uint256 revealDeadline;     // reveals allowed in (submission, reveal]
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        uint256 revealedCount;
        Submission[] submissions;
    }

    // Decoded shape of the LLM precompile output (mirrors workshop AIJudge).
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) public bounties;
    // bountyId => submitter => has already committed (one commit per bounty)
    mapping(uint256 => mapping(address => bool)) public hasCommitted;
    // bountyId => submitter => index in submissions[] (+1, 0 = none)
    mapping(uint256 => mapping(address => uint256)) private _submissionIndexPlus1;

    // ----------------------------------------------------------------- events
    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );
    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter,
        bytes32 commitment
    );
    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );
    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);
    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    // ----------------------------------------------------------------- errors
    error BountyNotFound();
    error NotBountyOwner();
    error RewardRequired();
    error BadDeadlines();
    error SubmissionsClosed();
    error AlreadyCommitted();
    error TooManySubmissions();
    error RevealNotOpen();
    error RevealClosed();
    error NothingToReveal();
    error AlreadyRevealed();
    error CommitmentMismatch();
    error AnswerTooLong();
    error AlreadyJudged();
    error AlreadyFinalized();
    error RevealPhaseNotOver();
    error NoRevealedAnswers();
    error NotJudgedYet();
    error WinnerNotRevealed();
    error InvalidWinnerIndex();
    error PaymentFailed();

    // ----------------------------------------------------------------- modifiers
    modifier bountyExists(uint256 bountyId) {
        if (bounties[bountyId].owner == address(0)) revert BountyNotFound();
        _;
    }

    modifier onlyOwner(uint256 bountyId) {
        if (msg.sender != bounties[bountyId].owner) revert NotBountyOwner();
        _;
    }

    // ------------------------------------------------------------- constructor
    /// @dev Bakes the deployer's address in as the verifiable builder identity.
    constructor() {
        BUILDER_ADDRESS = msg.sender;
    }

    // ----------------------------------------------------------------- create
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        if (msg.value == 0) revert RewardRequired();
        // Deadlines must be in the future and strictly ordered.
        if (
            submissionDeadline <= block.timestamp ||
            revealDeadline <= submissionDeadline
        ) revert BadDeadlines();

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    // --------------------------------------------------------------- 1) commit
    /**
     * @notice Submit a commitment hash during the submission phase.
     * @dev commitment MUST equal
     *      keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)).
     *      One commitment per (bounty, address).
     */
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        if (block.timestamp >= bounty.submissionDeadline)
            revert SubmissionsClosed();
        if (hasCommitted[bountyId][msg.sender]) revert AlreadyCommitted();
        if (bounty.submissions.length >= MAX_SUBMISSIONS)
            revert TooManySubmissions();

        bounty.submissions.push(
            Submission({
                submitter: msg.sender,
                commitment: commitment,
                answer: "",
                revealed: false
            })
        );

        uint256 idx = bounty.submissions.length - 1;
        hasCommitted[bountyId][msg.sender] = true;
        _submissionIndexPlus1[bountyId][msg.sender] = idx + 1;

        emit CommitmentSubmitted(bountyId, idx, msg.sender, commitment);
    }

    // --------------------------------------------------------------- 2) reveal
    /**
     * @notice Reveal the answer + salt after the submission deadline.
     * @dev Valid only if
     *      keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     *      == stored commitment. Including msg.sender and bountyId stops another
     *      participant from copying a commitment and revealing it as their own.
     */
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        if (block.timestamp < bounty.submissionDeadline) revert RevealNotOpen();
        if (block.timestamp >= bounty.revealDeadline) revert RevealClosed();
        if (bytes(answer).length > MAX_ANSWER_LENGTH) revert AnswerTooLong();

        uint256 idxPlus1 = _submissionIndexPlus1[bountyId][msg.sender];
        if (idxPlus1 == 0) revert NothingToReveal();
        uint256 idx = idxPlus1 - 1;

        Submission storage sub = bounty.submissions[idx];
        if (sub.revealed) revert AlreadyRevealed();

        bytes32 expected = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        if (expected != sub.commitment) revert CommitmentMismatch();

        sub.answer = answer;
        sub.revealed = true;
        bounty.revealedCount += 1;

        emit AnswerRevealed(bountyId, idx, msg.sender);
    }

    // --------------------------------------------------------------- 3) judge
    /**
     * @notice Batch-judge every revealed answer in a single Ritual LLM call.
     * @dev `llmInput` is built off-chain (see web/src/lib/ritualLlm.ts) and must
     *      contain ONLY revealed answers. Callable only after the reveal
     *      deadline so all eligible answers are public and final.
     */
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        if (block.timestamp < bounty.revealDeadline) revert RevealPhaseNotOver();
        if (bounty.judged) revert AlreadyJudged();
        if (bounty.finalized) revert AlreadyFinalized();
        if (bounty.revealedCount == 0) revert NoRevealedAnswers();

        bytes memory completionData = _runLlm(llmInput);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    /**
     * @dev Isolated so tests can override the precompile boundary. Production
     *      path calls the Ritual LLM inference precompile (0x0802) and decodes
     *      the short-running async return shape.
     */
    function _runLlm(bytes calldata llmInput)
        internal
        virtual
        returns (bytes memory completionData)
    {
        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        bool hasError;
        string memory errorMessage;
        (hasError, completionData, , errorMessage, ) = abi.decode(
            output,
            (bool, bytes, bytes, string, ConvoHistory)
        );
        require(!hasError, errorMessage);
    }

    // ------------------------------------------------------------ 4) finalize
    /**
     * @notice Owner finalizes one winner (human-in-the-loop) and pays out.
     * @dev AI output is advisory; the human owner picks `winnerIndex`. Winner
     *      must be a revealed submission. Reward is zeroed before transfer
     *      (checks-effects-interactions) to block reentrancy.
     */
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        if (!bounty.judged) revert NotJudgedYet();
        if (bounty.finalized) revert AlreadyFinalized();
        if (winnerIndex >= bounty.submissions.length)
            revert InvalidWinnerIndex();

        Submission storage win = bounty.submissions[winnerIndex];
        if (!win.revealed) revert WinnerNotRevealed();

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = win.submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        if (!ok) revert PaymentFailed();

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // ----------------------------------------------------------------- views
    function getBounty(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 submissionDeadline,
            uint256 revealDeadline,
            bool judged,
            bool finalized,
            uint256 submissionCount,
            uint256 revealedCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage b = bounties[bountyId];
        return (
            b.owner,
            b.title,
            b.rubric,
            b.reward,
            b.submissionDeadline,
            b.revealDeadline,
            b.judged,
            b.finalized,
            b.submissions.length,
            b.revealedCount,
            b.winnerIndex,
            b.aiReview
        );
    }

    /**
     * @notice Read a submission. Before reveal, `answer` is empty and `revealed`
     *         is false — that is the whole point: plaintext is hidden during the
     *         submission phase.
     */
    function getSubmission(uint256 bountyId, uint256 index)
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bytes32 commitment,
            string memory answer,
            bool revealed
        )
    {
        Bounty storage b = bounties[bountyId];
        require(index < b.submissions.length, "invalid index");
        Submission storage s = b.submissions[index];
        return (s.submitter, s.commitment, s.answer, s.revealed);
    }

    function getSubmissionCount(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (uint256)
    {
        return bounties[bountyId].submissions.length;
    }

    /**
     * @notice Convenience helper so a client can compute the commitment exactly
     *         the way the contract verifies it. Pure — safe to call off-chain.
     */
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }
}
