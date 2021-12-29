// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../utils/Ownable.sol";
import "../libraries/SafePRBMath.sol";
import "./interfaces/IRandomNumberGenerator.sol";

contract DegisLottery is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafePRBMath for uint256;

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Variables **************************************** //
    // ---------------------------------------------------------------------------------------- //

    IRandomNumberGenerator randomGenerator;

    address public operatorAddress;

    uint256 public currentLotteryId;

    uint256 public TICKET_PRICE = 10 ether;

    uint256 public constant MAX_TICKET_NUMBER = 9999;
    uint256 public constant MIN_TICKET_NUMBER = 0;

    uint256 public maxTicketsPerTx = 10;

    IERC20 public degis;
    IERC20 public USD;

    enum Status {
        Pending,
        Open,
        Close,
        Claimbale
    }

    struct LotteryInfo {
        Status status;
        uint256 startTime;
        uint256 endTime;
        uint256[4] rewardsBreakdown;
        uint256[4] rewardsPerLevel;
        uint256[4] ticketAmount;
        uint256[4] ticketWeight;
        uint256 totalReward;
        uint256 pendingReward;
        uint32 finalNumber;
    }
    mapping(uint256 => LotteryInfo) public lotteryList;

    struct TicketInfo {
        uint32 number;
        bool isRedeemed;
        uint256 buyLotteryId;
        uint256 redeemLotteryId;
        uint256 price;
        address owner;
    }
    mapping(uint256 => TicketInfo) private ticketList;

    struct Tickets {
        mapping(uint256 => uint256) ticketsWeight; // encodedNumber => Weight
        mapping(uint256 => uint256) ticketsAmount; // encodedNumber => Amount
    }
    Tickets poolTickets;

    mapping(address => Tickets) userTickets;

    // ---------------------------------------------------------------------------------------- //
    // *************************************** Events ***************************************** //
    // ---------------------------------------------------------------------------------------- //

    event RandomGeneratorChanged(address oldGenerator, address newGenerator);
    event OperatorAddressChanged(address newOperator);

    event TicketsPurchased(
        address buyerAddress,
        uint256 lotteryId,
        uint256 startTicketId,
        uint256 endTicketId
    );

    event EmergencyWithdraw(address indexed tokenAddress, uint256 amount);

    event LotteryFundInjection(uint256 lotteryId, uint256 amount);

    /**
     * @notice Constructor function
     * @dev RandomNumberGenerator must be deployed prior to this contract
     * @param _degisTokenAddress Address of the DEGIS token (for buying tickets)
     * @param _usdcTokenAddress Address of the USDC token (for prize distribution)
     * @param _randomGeneratorAddress Address of the RandomGenerator contract used to work with ChainLink VRF
     */
    constructor(
        address _degisTokenAddress,
        address _usdcTokenAddress,
        address _randomGeneratorAddress
    ) {
        degis = IERC20(_degisTokenAddress);
        USD = IERC20(_usdcTokenAddress);
        randomGenerator = IRandomNumberGenerator(_randomGeneratorAddress);
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************** Modifiers *************************************** //
    // ---------------------------------------------------------------------------------------- //

    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    modifier notZeroAddress(address _address) {
        require(_address != address(0), "Can not give 0 address");
        _;
    }

    modifier validTicketNumber(uint256 _number) {
        require(
            _number <= MAX_TICKET_NUMBER && _number >= MIN_TICKET_NUMBER,
            "Ticket number out of range"
        );
        _;
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ View Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Get all lotteries' information
     */
    function getAllLotteryInfo() external view returns (LotteryInfo[] memory) {
        LotteryInfo[] memory allLotteries = new LotteryInfo[](currentLotteryId);
        for (uint256 i = 1; i <= currentLotteryId; i++) {
            allLotteries[i - 1] = lotteryList[i];
        }
        return allLotteries;
    }

    /**
     * @notice Get a ticket's information
     */
    function getTicketInfo(uint256 _ticketId)
        external
        view
        returns (TicketInfo memory)
    {
        return ticketList[_ticketId];
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Set Functions ************************************* //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Set the random generator contract address
     * @param _randomGenerator Address of random generator
     */
    function setRandomGenerator(address _randomGenerator)
        external
        onlyOwner
        notZeroAddress(_randomGenerator)
    {
        address oldGenerator = address(randomGenerator);
        randomGenerator = IRandomNumberGenerator(_randomGenerator);
        emit RandomGeneratorChanged(oldGenerator, _randomGenerator);
    }

    /**
     * @notice Set a new operator addresses
     * @dev Only callable by the owner
     * @param _operatorAddress address of the operator
     */
    function setOperatorAddresses(address _operatorAddress)
        external
        onlyOwner
        notZeroAddress(_operatorAddress)
    {
        operatorAddress = _operatorAddress;

        emit OperatorAddressChanged(_operatorAddress);
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Main Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    function buyTickets(
        uint256[] calldata _ticketNumbers,
        uint256[] calldata _ticketAmounts
    ) external nonReentrant {
        // Note: CALLDATALOAD 3 gas, CALLDATASIZE 2 gas, MLOAD & MSTORE 3 gas
        uint256 ticketAmount = _ticketNumbers.length;
        require(ticketAmount != 0, "No tickets are being bought");

        require(
            ticketAmount == _ticketAmounts.length,
            "Length of ticket number and amount are different"
        );

        require(
            ticketAmount <= maxTicketsPerTx,
            "Too many tickets are bought at one time"
        );

        require(
            lotteryList[currentLotteryId].status == Status.Open,
            "Current lottery is not open"
        );

        uint256 degisAmountToPay = TICKET_PRICE * ticketAmount;

        degis.safeTransferFrom(_msgSender(), address(this), degisAmountToPay);

        uint256 currentRoundWeight = getCurrentRoundWeight();

        for (uint256 i = 0; i < ticketAmount; i++) {
            uint256 number = _ticketNumbers[i];

            require(
                number >= MIN_TICKET_NUMBER && number <= MAX_TICKET_NUMBER,
                "Ticket number is out of range"
            );

            _buyTicket(
                poolTickets,
                _ticketNumbers[i],
                _ticketAmounts[i],
                currentRoundWeight * _ticketAmounts[i]
            );

            _buyTicket(
                usersTickets[msg.sender],
                _ticketNumbers[i],
                _ticketAmounts[i],
                currentRoundWeight * _ticketAmounts[i]
            );

            totalAmount += _ticketAmounts[i];
        }

        emit TicketsPurchased(
            _msgSender(),
            currentLotteryId,
            startTicketId,
            currentTicketId - 1
        );
    }

    function getCurrentRoundWeight() public view returns (uint256) {
        return ((currentLotteryId + 24) * 1000000) / (currentLotteryId + 12);
    }

    function redeemTickets(uint256[] calldata _ticketIds) external {}

    function claimTickets(uint256 _lotteryId, uint256[] calldata _ticketIds)
        external
    {}

    function claimAllTickets(uint256 _lotteryId) external {}

    function startLottery(
        uint256 _endTime,
        uint256 _ticketPrice,
        uint256[4] calldata _rewardsBreakdown
    ) external {}

    function closeLottery(uint256 _lotteryId) external {}

    function injectFunds(uint256 _amount) external nonReentrant {
        require(
            lotteryList[currentLotteryId].status == Status.Open,
            "Current lottery round is not open"
        );

        USD.safeTransferFrom(_msgSender(), address(this), _amount);

        lotteryList[currentLotteryId].pendingReward += _amount;

        require(
            lotteryList[currentLotteryId].pendingReward <=
                USD.balanceOf(address(this)),
            "the amount is wrong"
        );

        emit LotteryFundInjection(currentLotteryId, _amount);
    }

    function drawFinalNumber(uint256 _lotteryId, bool _autoInjection)
        external
    {}

    function emergencyWithdraw(address _tokenAddress, uint256 _amount)
        external
        onlyOwner
    {
        require(
            _tokenAddress != address(degis),
            "Can not withdraw degis tokens"
        );

        IERC20(_tokenAddress).safeTransfer(owner(), _amount);

        emit EmergencyWithdraw(_tokenAddress, _amount);
    }

    // ---------------------------------------------------------------------------------------- //
    // *********************************** Internal Functions ********************************* //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Check if an address is a contract
     */
    function _isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }
}