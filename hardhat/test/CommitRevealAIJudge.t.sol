// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitRevealAIJudge} from "../contracts/CommitRevealAIJudge.sol";

/**
 * @dev Test harness: overrides the precompile boundary so unit tests run on a
 *      plain EVM (Hardhat/Foundry) without the Ritual LLM precompile at 0x0802.
 *      `_runLlm` just echoes a canned AI review. Every other line of logic
 *      (commit, reveal, deadlines, eligibility, payout) is the real contract.
 */
contract Harness is CommitRevealAIJudge {
    bytes public lastLlmInput;

    function _runLlm(bytes calldata llmInput)
        internal
        override
        returns (bytes memory)
    {
        lastLlmInput = llmInput;
        return bytes('{"winnerIndex":0,"summary":"ok"}');
    }
}

contract CommitRevealAIJudgeTest is Test {
    Harness internal judge;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal subDeadline;
    uint256 internal revDeadline;
    uint256 internal constant REWARD = 1 ether;

    // mirror of the contract events for expectEmit
    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    function setUp() public {
        judge = new Harness();
        subDeadline = block.timestamp + 1 days;
        revDeadline = block.timestamp + 2 days;
        vm.deal(owner, 10 ether);
    }

    // --------------------------------------------------------------- helpers
    function _createBounty() internal returns (uint256 id) {
        vm.prank(owner);
        id = judge.createBounty{value: REWARD}(
            "Best gas optimization",
            "Lowest gas wins. Must compile.",
            subDeadline,
            revDeadline
        );
    }

    function _commitment(
        string memory answer,
        bytes32 salt,
        address who,
        uint256 bountyId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, who, bountyId));
    }

    function _commit(
        uint256 id,
        address who,
        string memory answer,
        bytes32 salt
    ) internal {
        bytes32 c = _commitment(answer, salt, who, id);
        vm.prank(who);
        judge.submitCommitment(id, c);
    }

    // =====================================================================
    //                       HAPPY PATH (end to end)
    // =====================================================================
    function test_FullLifecycle_HappyPath() public {
        uint256 id = _createBounty();

        // --- submission phase: only commitments, no plaintext on-chain ---
        _commit(id, alice, "use unchecked loops", bytes32(uint256(1)));
        _commit(id, bob, "pack structs tightly", bytes32(uint256(2)));

        // plaintext is hidden during submission phase
        (, , string memory ans0, bool revealed0) = judge.getSubmission(id, 0);
        assertEq(bytes(ans0).length, 0, "answer must be hidden pre-reveal");
        assertFalse(revealed0);

        // --- reveal phase ---
        vm.warp(subDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "use unchecked loops", bytes32(uint256(1)));
        vm.prank(bob);
        judge.revealAnswer(id, "pack structs tightly", bytes32(uint256(2)));

        (, , string memory ans0After, bool revealed0After) =
            judge.getSubmission(id, 0);
        assertEq(ans0After, "use unchecked loops");
        assertTrue(revealed0After);

        // --- judge after reveal deadline ---
        vm.warp(revDeadline + 1);
        vm.prank(owner);
        judge.judgeAll(id, hex"1234");

        (, , , , , , bool judged, , , uint256 revealedCount, , bytes memory ai) =
            judge.getBounty(id);
        assertTrue(judged);
        assertEq(revealedCount, 2);
        assertGt(ai.length, 0);

        // --- finalize: human owner picks winner, payout happens ---
        uint256 aliceBefore = alice.balance;
        vm.expectEmit(true, true, true, true);
        emit WinnerFinalized(id, 0, alice, REWARD);
        vm.prank(owner);
        judge.finalizeWinner(id, 0);

        assertEq(alice.balance, aliceBefore + REWARD, "winner paid");
        (, , , uint256 reward, , , , bool finalized, , , uint256 winIdx, ) =
            judge.getBounty(id);
        assertTrue(finalized);
        assertEq(reward, 0);
        assertEq(winIdx, 0);
    }

    // =====================================================================
    //                       COMMIT PHASE — invalid cases
    // =====================================================================
    function test_Commit_RevertAfterDeadline() public {
        uint256 id = _createBounty();
        vm.warp(subDeadline);
        bytes32 c = _commitment("x", bytes32(uint256(1)), alice, id);
        vm.prank(alice);
        vm.expectRevert(CommitRevealAIJudge.SubmissionsClosed.selector);
        judge.submitCommitment(id, c);
    }

    function test_Commit_RevertDoubleCommit() public {
        uint256 id = _createBounty();
        _commit(id, alice, "first", bytes32(uint256(1)));
        bytes32 c = _commitment("second", bytes32(uint256(9)), alice, id);
        vm.prank(alice);
        vm.expectRevert(CommitRevealAIJudge.AlreadyCommitted.selector);
        judge.submitCommitment(id, c);
    }

    function test_Commit_RevertUnknownBounty() public {
        bytes32 c = _commitment("x", bytes32(uint256(1)), alice, 999);
        vm.prank(alice);
        vm.expectRevert(CommitRevealAIJudge.BountyNotFound.selector);
        judge.submitCommitment(999, c);
    }

    // =====================================================================
    //                       REVEAL PHASE — invalid cases
    // =====================================================================
    function test_Reveal_RevertBeforeSubmissionDeadline() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer", bytes32(uint256(1)));
        // still in submission phase
        vm.prank(alice);
        vm.expectRevert(CommitRevealAIJudge.RevealNotOpen.selector);
        judge.revealAnswer(id, "answer", bytes32(uint256(1)));
    }

    function test_Reveal_RevertAfterRevealDeadline() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer", bytes32(uint256(1)));
        vm.warp(revDeadline);
        vm.prank(alice);
        vm.expectRevert(CommitRevealAIJudge.RevealClosed.selector);
        judge.revealAnswer(id, "answer", bytes32(uint256(1)));
    }

    function test_Reveal_RevertWrongAnswer() public {
        uint256 id = _createBounty();
        _commit(id, alice, "real answer", bytes32(uint256(1)));
        vm.warp(subDeadline + 1);
        vm.prank(alice);
        vm.expectRevert(CommitRevealAIJudge.CommitmentMismatch.selector);
        judge.revealAnswer(id, "tampered answer", bytes32(uint256(1)));
    }

    function test_Reveal_RevertWrongSalt() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer", bytes32(uint256(1)));
        vm.warp(subDeadline + 1);
        vm.prank(alice);
        vm.expectRevert(CommitRevealAIJudge.CommitmentMismatch.selector);
        judge.revealAnswer(id, "answer", bytes32(uint256(42)));
    }

    /// @notice Front-running guard: bob copied alice's commitment but cannot
    ///         reveal it, because msg.sender is bound into the hash.
    function test_Reveal_RevertStolenCommitment() public {
        uint256 id = _createBounty();
        bytes32 salt = bytes32(uint256(7));
        bytes32 aliceCommit = _commitment("alice idea", salt, alice, id);

        // alice commits
        vm.prank(alice);
        judge.submitCommitment(id, aliceCommit);

        // bob commits the SAME hash he copied from the mempool
        vm.prank(bob);
        judge.submitCommitment(id, aliceCommit);

        vm.warp(subDeadline + 1);
        // bob tries to reveal alice's answer as his own -> hash uses bob's addr
        vm.prank(bob);
        vm.expectRevert(CommitRevealAIJudge.CommitmentMismatch.selector);
        judge.revealAnswer(id, "alice idea", salt);
    }

    function test_Reveal_RevertNoCommitment() public {
        uint256 id = _createBounty();
        vm.warp(subDeadline + 1);
        vm.prank(carol);
        vm.expectRevert(CommitRevealAIJudge.NothingToReveal.selector);
        judge.revealAnswer(id, "anything", bytes32(uint256(1)));
    }

    function test_Reveal_RevertDoubleReveal() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer", bytes32(uint256(1)));
        vm.warp(subDeadline + 1);
        vm.startPrank(alice);
        judge.revealAnswer(id, "answer", bytes32(uint256(1)));
        vm.expectRevert(CommitRevealAIJudge.AlreadyRevealed.selector);
        judge.revealAnswer(id, "answer", bytes32(uint256(1)));
        vm.stopPrank();
    }

    // =====================================================================
    //                       JUDGE — invalid cases
    // =====================================================================
    function test_Judge_RevertBeforeRevealDeadline() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer", bytes32(uint256(1)));
        vm.warp(subDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "answer", bytes32(uint256(1)));
        // reveal deadline not reached
        vm.prank(owner);
        vm.expectRevert(CommitRevealAIJudge.RevealPhaseNotOver.selector);
        judge.judgeAll(id, hex"00");
    }

    function test_Judge_RevertNotOwner() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer", bytes32(uint256(1)));
        vm.warp(subDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "answer", bytes32(uint256(1)));
        vm.warp(revDeadline + 1);
        vm.prank(bob);
        vm.expectRevert(CommitRevealAIJudge.NotBountyOwner.selector);
        judge.judgeAll(id, hex"00");
    }

    function test_Judge_RevertNoRevealedAnswers() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer", bytes32(uint256(1)));
        // nobody reveals
        vm.warp(revDeadline + 1);
        vm.prank(owner);
        vm.expectRevert(CommitRevealAIJudge.NoRevealedAnswers.selector);
        judge.judgeAll(id, hex"00");
    }

    function test_Judge_RevertDoubleJudge() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer", bytes32(uint256(1)));
        vm.warp(subDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "answer", bytes32(uint256(1)));
        vm.warp(revDeadline + 1);
        vm.startPrank(owner);
        judge.judgeAll(id, hex"00");
        vm.expectRevert(CommitRevealAIJudge.AlreadyJudged.selector);
        judge.judgeAll(id, hex"00");
        vm.stopPrank();
    }

    // =====================================================================
    //                       FINALIZE — invalid cases
    // =====================================================================
    function test_Finalize_RevertBeforeJudge() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer", bytes32(uint256(1)));
        vm.warp(subDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "answer", bytes32(uint256(1)));
        vm.warp(revDeadline + 1);
        vm.prank(owner);
        vm.expectRevert(CommitRevealAIJudge.NotJudgedYet.selector);
        judge.finalizeWinner(id, 0);
    }

    function test_Finalize_RevertUnrevealedWinner() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer", bytes32(uint256(1))); // index 0, reveals
        _commit(id, bob, "secret", bytes32(uint256(2)));   // index 1, never reveals
        vm.warp(subDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "answer", bytes32(uint256(1)));
        vm.warp(revDeadline + 1);
        vm.startPrank(owner);
        judge.judgeAll(id, hex"00");
        // owner tries to pick the unrevealed bob
        vm.expectRevert(CommitRevealAIJudge.WinnerNotRevealed.selector);
        judge.finalizeWinner(id, 1);
        vm.stopPrank();
    }

    function test_Finalize_RevertInvalidIndex() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer", bytes32(uint256(1)));
        vm.warp(subDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "answer", bytes32(uint256(1)));
        vm.warp(revDeadline + 1);
        vm.startPrank(owner);
        judge.judgeAll(id, hex"00");
        vm.expectRevert(CommitRevealAIJudge.InvalidWinnerIndex.selector);
        judge.finalizeWinner(id, 99);
        vm.stopPrank();
    }

    function test_Finalize_RevertDoubleFinalize() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer", bytes32(uint256(1)));
        vm.warp(subDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "answer", bytes32(uint256(1)));
        vm.warp(revDeadline + 1);
        vm.startPrank(owner);
        judge.judgeAll(id, hex"00");
        judge.finalizeWinner(id, 0);
        vm.expectRevert(CommitRevealAIJudge.AlreadyFinalized.selector);
        judge.finalizeWinner(id, 0);
        vm.stopPrank();
    }

    // =====================================================================
    //                       CREATE — invalid cases
    // =====================================================================
    function test_Create_RevertNoReward() public {
        vm.prank(owner);
        vm.expectRevert(CommitRevealAIJudge.RewardRequired.selector);
        judge.createBounty("t", "r", subDeadline, revDeadline);
    }

    function test_Create_RevertBadDeadlines() public {
        vm.prank(owner);
        vm.expectRevert(CommitRevealAIJudge.BadDeadlines.selector);
        judge.createBounty{value: REWARD}("t", "r", revDeadline, subDeadline);
    }

    // =====================================================================
    //                       FUZZ — commitment integrity
    // =====================================================================
    function testFuzz_RevealMatchesCommitment(
        string calldata answer,
        bytes32 salt
    ) public {
        vm.assume(bytes(answer).length <= judge.MAX_ANSWER_LENGTH());
        uint256 id = _createBounty();
        bytes32 c = _commitment(answer, salt, alice, id);
        vm.prank(alice);
        judge.submitCommitment(id, c);
        vm.warp(subDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, answer, salt); // must not revert
        (, , string memory stored, bool revealed) = judge.getSubmission(id, 0);
        assertEq(stored, answer);
        assertTrue(revealed);
    }
}
