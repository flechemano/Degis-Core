// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../tokens/interfaces/IBuyerToken.sol";
import "../tokens/interfaces/IDegisToken.sol";
import "../utils/Ownable.sol";
import "../libraries/SafePRBMath.sol";

import "hardhat/console.sol";

/**
 * @title  Purchase Incentive Vault
 * @notice This is the purchase incentive vault for staking buyer tokens.
 *         Users first stake their buyer tokens and wait for distribution.
 *         About every 24 hours, the reward will be calculated to users' account.
 *         After disrtribution, users' reward balance will update but they still need to manually claim the reward.
 */
contract PurchaseIncentiveVault is Ownable {
    using SafeERC20 for IBuyerToken;
    using SafePRBMath for uint256;

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Variables **************************************** //
    // ---------------------------------------------------------------------------------------- //

    // Other contracts
    IBuyerToken buyerToken;
    IDegisToken degis;

    // Current round number
    uint256 public currentRound;

    // Degis reward per round
    uint256 public degisPerRound;

    // The interval will only limit the distribution (not the staking)
    uint256 public distributionInterval;

    // Last distribution block
    uint256 public lastDistributionBlock;

    uint256 public MAX_ROUND = 50;

    // Current distribution index
    uint256 currentDistributionIndex;

    struct RoundInfo {
        uint256 shares;
        address[] users;
        bool hasDistributed;
        uint256 degisPerShare;
    }
    mapping(uint256 => RoundInfo) roundInfo;

    // // Round number => Total shares(buyer tokens)
    // mapping(uint256 => uint256) public sharesInRound;

    // // Round number => User address list
    // mapping(uint256 => address[]) public usersInRound;

    // // Round number => Whether has been distributed
    // mapping(uint256 => bool) public hasDistributed;

    struct UserInfo {
        uint256 lastRewardRound;
        uint256[] pendingRounds;
    }
    mapping(address => UserInfo) userInfo;

    // User address => Round number => User shares
    mapping(address => mapping(uint256 => uint256)) public userSharesInRound;

    // User address => Pending rewards
    mapping(address => uint256) public userRewards;

    mapping(address => uint256) public userLastRewardRound;

    // ---------------------------------------------------------------------------------------- //
    // *************************************** Events ***************************************** //
    // ---------------------------------------------------------------------------------------- //

    event DegisPerRoundChanged(uint256 oldPerRound, uint256 newPerRound);
    event DistributionIntervalChanged(uint256 oldInterval, uint256 newInterval);
    event Stake(address userAddress, uint256 currentRound, uint256 amount);
    event Redeem(address userAddress, uint256 currentRound, uint256 amount);
    event RewardClaimed(address userAddress, uint256 userReward);

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Constructor ************************************** //
    // ---------------------------------------------------------------------------------------- //

    constructor(address _buyerToken, address _degisToken) {
        // Initialize two tokens
        buyerToken = IBuyerToken(_buyerToken);
        degis = IDegisToken(_degisToken);

        // Initialize the last distribution block
        lastDistributionBlock = block.number;
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************** Modifiers *************************************** //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Check if admins can distribute at this time
     */
    modifier hasPassedInterval() {
        require(
            block.number - lastDistributionBlock > distributionInterval,
            "Two distributions need to have an interval "
        );
        _;
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ View Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Get the amount of users in _round, used for distribution
     * @param _round Round number to check
     * @return totalUsers Total amount of users in _round
     */
    function getTotalUsersInRound(uint256 _round)
        public
        view
        returns (uint256)
    {
        return roundInfo[_round].users.length;
    }

    /**
     * @notice Get your shares in the current round
     * @param _userAddress Address of the user
     */
    function getUserShares(address _userAddress) public view returns (uint256) {
        return userSharesInRound[_userAddress][currentRound];
    }

    /**
     * @notice Get a user's pending reward
     * @return userPendingReward User's pending reward
     */
    function pendingReward() public view returns (uint256) {
        UserInfo memory user = userInfo[_msgSender()];

        uint256 length = user.pendingRounds.length - user.lastRewardRound;
        uint256 startIndex = user.lastRewardRound;

        uint256 userPendingReward;
        for (uint256 i = startIndex; i < startIndex + length; i++) {
            uint256 round = user.pendingRounds[i];

            userPendingReward += roundInfo[round].degisPerShare.mul(
                userSharesInRound[_msgSender()][round]
            );
        }

        return userPendingReward;
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Set Functions ************************************* //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Set degis distribution per round
     * @param _degisPerRound Degis distribution per round to be set
     */
    function setDegisPerRound(uint256 _degisPerRound) external onlyOwner {
        uint256 oldPerRound = degisPerRound;
        degisPerRound = _degisPerRound;
        emit DegisPerRoundChanged(oldPerRound, _degisPerRound);
    }

    /**
     * @notice Set a new distribution interval
     * @param _newInterval The new interval
     */
    function setDistributionInterval(uint256 _newInterval) external onlyOwner {
        uint256 oldInterval = distributionInterval;
        distributionInterval = _newInterval;
        emit DistributionIntervalChanged(oldInterval, _newInterval);
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Main Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Stake buyer tokens into this contract
     * @param _amount Amount of buyer tokens to stake
     */
    function stake(uint256 _amount) external {
        buyerToken.safeTransferFrom(_msgSender(), address(this), _amount);

        if (userSharesInRound[_msgSender()][currentRound] == 0) {
            roundInfo[currentRound].users.push(_msgSender());
        }

        userSharesInRound[_msgSender()][currentRound] += _amount;

        if (userInfo[_msgSender()].pendingRounds.length == 0)
            userInfo[_msgSender()].lastRewardRound = currentRound;

        userInfo[_msgSender()].pendingRounds.push(currentRound);

        roundInfo[currentRound].shares += _amount;

        emit Stake(_msgSender(), currentRound, _amount);
    }

    /**
     * @notice Redeem buyer token from the vault
     * @param _amount Amount to redeem
     */
    function redeem(uint256 _amount) external {
        uint256 userBalance = userSharesInRound[_msgSender()][currentRound];
        require(
            userBalance >= _amount,
            "Not enough buyer tokens for you to redeem"
        );

        buyerToken.safeTransfer(_msgSender(), _amount);

        userSharesInRound[_msgSender()][currentRound] -= _amount;

        userInfo[_msgSender()].pendingRounds.pop();

        roundInfo[currentRound].shares -= _amount;

        emit Redeem(_msgSender(), currentRound, _amount);
    }

    /**
     * @notice Setttle the current round
     */
    function settleCurrentRound() external onlyOwner {
        RoundInfo storage info = roundInfo[currentRound];
        require(info.hasDistributed == false, "Already distributed this round");

        uint256 totalShares = info.shares;

        info.degisPerShare = degisPerRound.div(totalShares);
        info.hasDistributed = true;

        currentRound += 1;
        lastDistributionBlock = block.number;
    }

    /**
     * @notice User can claim his own reward
     */
    function claimOwnReward() external {
        UserInfo memory user = userInfo[_msgSender()];

        require(user.pendingRounds.length != 0, "You have no shares ever");

        uint256 length = user.pendingRounds.length - user.lastRewardRound;
        uint256 startIndex = user.lastRewardRound;
        if (length > MAX_ROUND) {
            length = MAX_ROUND;

            userInfo[_msgSender()].lastRewardRound = user.pendingRounds[
                MAX_ROUND
            ];
        } else
            userInfo[_msgSender()].lastRewardRound =
                user.pendingRounds[length - 1] +
                1;

        uint256 gas_before = gasleft();

        uint256 userPendingReward;

        for (uint256 i = startIndex; i < startIndex + length; i++) {
            uint256 round = user.pendingRounds[i];

            userPendingReward += roundInfo[round].degisPerShare.mul(
                userSharesInRound[_msgSender()][round]
            );
        }

        uint256 gas_after = gasleft();

        degis.mintDegis(_msgSender(), userPendingReward);

        console.log("Gas Used:", gas_before - gas_after);
    }

    // /**
    //  * @notice Distribute the reward in this round, the total number depends on the blocks during this period
    //  * @param _startIndex Distribution start index
    //  * @param _stopIndex Distribution stop index
    //  */
    // function distributeReward(uint256 _startIndex, uint256 _stopIndex)
    //     external
    //     onlyOwner
    //     hasPassedInterval
    // {
    //     require(
    //         degisPerRound > 0,
    //         "Currently no Degis reward, please set degisPerRound first"
    //     );
    //     require(
    //         roundInfo[currentRound].hasDistributed == false,
    //         "Current round has been distributed"
    //     );

    //     uint256 totalShares = roundInfo[currentRound].shares;
    //     uint256 degisPerShare = degisPerRound.div(totalShares);

    //     uint256 length = getTotalUsersInRound(currentRound);

    //     // Distribute all at once
    //     // Maybe not enough gas in one tx, the judgement should be done by backend)
    //     if (_startIndex == 0 && _stopIndex == 0) {
    //         _distributeReward(currentRound, 0, length, degisPerShare);
    //         currentDistributionIndex = length;
    //     }
    //     // Distribute in a certain range (need several times distribution)
    //     else {
    //         // Check if you start from the last check point
    //         require(
    //             currentDistributionIndex == _startIndex,
    //             "You need to start from the last distribution point"
    //         );
    //         // Check if the stopindex exceeds the length
    //         _stopIndex = _stopIndex > length ? length : _stopIndex;

    //         if (_stopIndex != 0) {
    //             _distributeReward(
    //                 currentRound,
    //                 _startIndex,
    //                 _stopIndex,
    //                 degisPerShare
    //             );
    //         }

    //         currentDistributionIndex = _stopIndex;
    //     }

    //     if (currentDistributionIndex == length) {
    //         _finishDistribution();
    //     }
    // }

    // /**
    //  * @notice Users need to claim their overall rewards
    //  */
    // function claimReward() external {
    //     uint256 userReward = userRewards[_msgSender()];

    //     require(userReward > 0, "You do not have any rewards to claim");

    //     degis.mintDegis(_msgSender(), userReward);

    //     delete userRewards[_msgSender()];

    //     emit RewardClaimed(_msgSender(), userReward);
    // }

    // ---------------------------------------------------------------------------------------- //
    // *********************************** Internal Functions ********************************* //
    // ---------------------------------------------------------------------------------------- //

    // /**
    //  * @notice Finish the distribution process
    //  * @param _round Distribution round
    //  * @param _startIndex Start index
    //  * @param _stopIndex Stop index
    //  * @param _degisPerShare Amount of degis per share
    //  */
    // function _distributeReward(
    //     uint256 _round,
    //     uint256 _startIndex,
    //     uint256 _stopIndex,
    //     uint256 _degisPerShare
    // ) internal {
    //     for (uint256 i = _startIndex; i < _stopIndex; i++) {
    //         address userAddress = usersInRound[_round][i];
    //         uint256 userShares = userSharesInRound[userAddress][_round];

    //         buyerToken.burnBuyerToken(address(this), userShares);

    //         if (userShares != 0) {
    //             // Update the pending reward of a user
    //             userRewards[userAddress] += userShares.mul(_degisPerShare);
    //             delete userSharesInRound[userAddress][_round];
    //         } else continue;
    //     }
    // }

    // /**
    //  * @notice Finish the distribution process and move to next round
    //  */
    // function _finishDistribution() internal {
    //     currentDistributionIndex = 0;
    //     hasDistributed[currentRound] = true;
    //     currentRound += 1;
    //     lastDistributionBlock = block.number;
    // }
}
