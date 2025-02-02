// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IERC20Extended is IERC20 {}

contract NeoLanceEscrow is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20Extended;
    
    IERC20Extended public stablecoin;
    uint256 public disputeFee = 10 * 10**18;
    uint256 public escrowExpiryTime = 30 days;
    uint256 public constant MIN_VOTER = 3;

    struct Escrow {
        address client;
        address freelancer;
        uint256 amount;
        uint256 releasedAmount;
        bool isActive;
        uint256 deadline;
        bool isDisputed;
        bool isSigned;
        bool isSubmitted;
        uint256 createdAt;
    }

    struct Review {
        uint8 clientRating;
        string clientFeedback;
        uint8 freelancerRating;
        string freelancerFeedback;
        uint256 timestamp;
        bool exists;
    }

    struct Vote {
        bool voted;
        bool voteForFreelancer;
    }

    mapping(uint256 => Escrow) public escrows;
    mapping(uint256 => Review[]) public reviewHistory;
    mapping(uint256 => mapping(address => Vote)) public disputeVotes;
    mapping(uint256 => uint256) public votesForFreelancer;
    mapping(uint256 => uint256) public votesForClient;
    uint256 public escrowCount;

    event EscrowCreated(uint256 indexed escrowId, address indexed client, address indexed freelancer, uint256 amount, uint256 deadline, uint256 timestamp);
    event ContractSigned(uint256 indexed escrowId, uint256 timestamp);
    event WorkSubmitted(uint256 indexed escrowId, address freelancer, uint256 timestamp);
    event MilestoneReleased(uint256 indexed escrowId, uint256 milestoneAmount, uint256 totalReleased, uint256 remainingBalance, uint256 timestamp);
    event PartialRefund(uint256 indexed escrowId, address client, uint256 refundAmount, uint256 timestamp);
    event WorkApproved(uint256 indexed escrowId, address freelancer, uint256 amount, uint256 timestamp);
    event Withdraw(uint256 indexed escrowId, address client, uint256 amount, uint256 timestamp);
    event PaymentReleased(uint256 indexed escrowId, address freelancer, uint256 amount, uint256 timestamp);
    event AutoReleased(uint256 indexed escrowId, address freelancer, uint256 amount, uint256 timestamp);
    event DisputeOpened(uint256 indexed escrowId, uint256 timestamp);
    event VoteCast(uint256 indexed escrowId, address voter, bool voteForFreelancer, uint256 timestamp);
    event DisputeResolved(uint256 indexed escrowId, address winner, uint256 amount, uint256 timestamp);
    event DeadlineExtended(uint256 indexed escrowId, uint256 newDeadline, uint256 timestamp);
    event EscrowExpired(uint256 indexed escrowId, address client, uint256 amount, uint256 timestamp);
    event ReviewSubmitted(uint256 indexed escrowId, address reviewer, uint8 rating, string feedback, uint256 timestamp);

    receive() external payable {
        revert("ETH not accepted, use stablecoin");
    }

    fallback() external payable {
        revert("ETH not accepted, use stablecoin");
    }


    constructor(address _stablecoin) {
        require(_stablecoin != address(0), "Invalid token address");
        stablecoin = IERC20Extended(_stablecoin);
    }

    function depositEscrow(address _freelancer, uint256 _amount, uint256 _deadline) external nonReentrant {
        require(_freelancer != address(0), "Invalid freelancer address");
        require(_amount > 0, "Amount must be > 0");
        require(_deadline > 0, "Deadline must be > 0");
        require(stablecoin.balanceOf(msg.sender) >= _amount, "Insufficient Balance");
        require(stablecoin.transferFrom(msg.sender, address(this), _amount), "Transfer Failed");
        
        escrowCount++;
        escrows[escrowCount] = Escrow({
            client: msg.sender,
            freelancer: _freelancer,
            amount: _amount,
            releasedAmount: 0,
            isActive: true,
            deadline: block.timestamp + _deadline,
            isDisputed: false,
            isSigned: false,
            isSubmitted: false,
            createdAt: block.timestamp
        });

        emit EscrowCreated(escrowCount, msg.sender, _freelancer, _amount, block.timestamp + _deadline, block.timestamp);
    }

    function signContract(uint256 _escrowId) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(msg.sender == escrow.client || msg.sender == escrow.freelancer, "Not a participant");
        require(escrow.isActive, "Escrow is not active");
        require(!escrow.isSigned, "Already signed");
        escrow.isSigned = true;
        emit ContractSigned(_escrowId, block.timestamp);

    }

    function submitWork(uint256 _escrowId) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(msg.sender == escrow.freelancer, "Only freelancer can submit work");
        require(escrow.isActive, "Escrow is not active");
        require(escrow.isSigned, "Contract not signed");
        require(!escrow.isSubmitted, "Work already submitted");
        require(block.timestamp <= escrow.deadline, "Deadline passed");
        escrow.isSubmitted = true;
        emit WorkSubmitted(_escrowId, msg.sender, block.timestamp);

    }

    function releaseMilestone(uint256 _escrowId, uint256 _milestoneAmount) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(msg.sender == escrow.client, "Only client can release milestone");
        require(escrow.isActive, "Escrow not active");
        require(_milestoneAmount > 0, "Milestone must be > 0");
        require(escrow.releasedAmount + _milestoneAmount <= escrow.amount, "Exceeds escrow amount");
        escrow.releasedAmount += _milestoneAmount;
        stablecoin.safeTransfer(escrow.freelancer, _milestoneAmount);
        uint256 remainingBalance = escrow.amount - escrow.releasedAmount;
        emit MilestoneReleased(_escrowId, _milestoneAmount, escrow.releasedAmount, remainingBalance, block.timestamp);
    }

    function partialRefund(uint256 _escrowId, uint256 _refundAmount) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(msg.sender == escrow.client, "Only client can refund");
        require(escrow.isActive, "Escrow not active");
        require(block.timestamp > escrow.deadline, "Refund only allowed after deadline");
        uint256 remaining = escrow.amount - escrow.releasedAmount;
        require(_refundAmount > 0 && _refundAmount <= remaining, "Invalid refund amount");
        escrow.isActive = false;
        stablecoin.safeTransfer(escrow.client, _refundAmount);
        emit PartialRefund(_escrowId, escrow.client, _refundAmount, block.timestamp);
}


    function approveWork(uint256 _escrowId) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(msg.sender == escrow.client, "Only client can approve work");
        require(escrow.isActive, "Escrow is not active");
        require(escrow.isSigned, "Contract not signed");
        require(escrow.isSubmitted, "Work not submitted");
        require(!escrow.isDisputed, "Escrow in dispute");
        uint256 remaining = escrow.amount - escrow.releasedAmount;
        escrow.isActive = false;
        stablecoin.safeTransfer(escrow.freelancer, remaining);
        emit WorkApproved(_escrowId, escrow.freelancer, remaining, block.timestamp);
    }

    function withdraw(uint256 _escrowId) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(msg.sender == escrow.client, "Only client can withdraw");
        require(escrow.isActive, "Escrow is not active");
        require(!escrow.isSubmitted, "Work already submitted");
        require(block.timestamp > escrow.deadline, "Deadline not reached");
        escrow.isActive = false;
        stablecoin.safeTransfer(escrow.client, escrow.amount);
        emit Withdraw(_escrowId, escrow.client, escrow.amount, block.timestamp);
    }

    function autoRelease(uint256 _escrowId) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.deadline <= block.timestamp, "Deadline not reached");
        require(escrow.isActive, "Escrow not active");
        require(!escrow.isDisputed, "Escrow in dispute");
        uint256 remaining = escrow.amount - escrow.releasedAmount;
        escrow.isActive = false;
        stablecoin.safeTransfer(escrow.freelancer, remaining);
        emit AutoReleased(_escrowId, escrow.freelancer, remaining, block.timestamp);
    }

    function openDispute(uint256 _escrowId) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(msg.sender == escrow.client || msg.sender == escrow.freelancer, "Only participants can open dispute");
        require(escrow.isActive, "Escrow not active");
        require(!escrow.isDisputed, "Dispute already opened");
        require(stablecoin.balanceOf(msg.sender) >= disputeFee, "Insufficient balance for dispute fee");
        escrow.isDisputed = true;
        stablecoin.safeTransferFrom(msg.sender, address(this), disputeFee);
        emit DisputeOpened(_escrowId, block.timestamp);
    }

    function voteOnDispute(uint256 _escrowId, bool _voteForFreelancer) external nonReentrant {
        require(escrows[_escrowId].isDisputed, "No dispute for this escrow");
        Vote storage v = disputeVotes[_escrowId][msg.sender];
        require(!v.voted, "Already voted");
        v.voted = true;
        v.voteForFreelancer = _voteForFreelancer;
        if (_voteForFreelancer) {
            votesForFreelancer[_escrowId]++;
        } else {
            votesForClient[_escrowId]++;
        }
        emit VoteCast(_escrowId, msg.sender, _voteForFreelancer, block.timestamp);
    }

    function resolveDispute(uint256 _escrowId) external onlyOwner nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.isDisputed, "No dispute for this escrow");
        require(escrow.isActive, "Escrow not active");
        uint256 totalVotes = votesForFreelancer[_escrowId] + votesForClient[_escrowId];
        require(totalVotes >= MIN_VOTER, "Not enough voters to resolve dispute");
        bool favorFreelancer = votesForFreelancer[_escrowId] > votesForClient[_escrowId];
        escrow.isActive = false;
        escrow.isDisputed = false;
        uint256 remaining = escrow.amount - escrow.releasedAmount;
            if (favorFreelancer) {
             stablecoin.safeTransfer(escrow.freelancer, remaining);
             emit DisputeResolved(_escrowId, escrow.freelancer, remaining, block.timestamp);
    }   else {
             stablecoin.safeTransfer(escrow.client, remaining);
             emit DisputeResolved(_escrowId, escrow.client, remaining, block.timestamp);
    }
}

    function checkEscrowExpiry(uint256 _escrowId) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.isActive, "Escrow not active");
        require(block.timestamp >= escrow.createdAt + escrowExpiryTime, "Escrow not expired yet");
        escrow.isActive = false;
        stablecoin.safeTransfer(escrow.client, escrow.amount);
        emit EscrowExpired(_escrowId, escrow.client, escrow.amount, block.timestamp);
    }

    function extendDeadline(uint256 _escrowId, uint256 additionalTime) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(msg.sender == escrow.client || msg.sender == escrow.freelancer, "Only participants can extend deadline");
        require(escrow.isActive, "Escrow not active");
        require(additionalTime > 0, "Additional time must be > 0");
        escrow.deadline += additionalTime;
        emit DeadlineExtended(_escrowId, escrow.deadline, block.timestamp);
    }

    function submitReview(uint256 _escrowId, uint8 _clientRating, string calldata _clientFeedback, uint8 _freelancerRating, string calldata _freelancerFeedback) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(!escrows[_escrowId].isActive, "Escrow must be finished");
        require(_clientRating >= 1 && _clientRating <= 5, "Client rating must be between 1 and 5");
        require(_freelancerRating >= 1 && _freelancerRating <= 5, "Freelancer rating must be between 1 and 5");
        Review memory newReview = Review({
            clientRating: _clientRating,
            clientFeedback: _clientFeedback,
            freelancerRating: _freelancerRating,
            freelancerFeedback: _freelancerFeedback,
            timestamp: block.timestamp,
            exists: true
        });
        reviewHistory[_escrowId].push(newReview);
        emit ReviewSubmitted(_escrowId, msg.sender, _clientRating, _clientFeedback, block.timestamp);
    }

    function getReviewHistory(uint _escrowId) public view returns (Review[] memory) {
        return reviewHistory[_escrowId];
    }
}