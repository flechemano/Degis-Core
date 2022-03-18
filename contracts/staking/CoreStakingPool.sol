// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import "../utils/Ownable.sol";
import "./abstracts/BasePool.sol";

contract CoreStakingPool is Ownable, BasePool {
    // ---------------------------------------------------------------------------------------- //
    // ************************************* Constructor ************************************** //
    // ---------------------------------------------------------------------------------------- //

    constructor(
        address _degisToken,
        address _poolToken,
        address _factory,
        uint256 _startBlock,
        uint256 _degisPerBlock,
        bool _isFlashPool
    )
        Ownable(msg.sender)
        BasePool(
            _degisToken,
            _poolToken,
            _factory,
            _startBlock,
            _degisPerBlock,
            _isFlashPool
        )
    {}

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Main Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Stake function, will call the stake in BasePool
     */
    function _stake(
        address _user,
        uint256 _amount,
        uint256 _lockUntil
    ) internal override {
        super._stake(_user, _amount, _lockUntil);
    }

    /**
     * @notice Unstake function, will check some conditions and call the unstake in BasePool
     */
    function _unstake(
        address _user,
        uint256 _depositId,
        uint256 _amount
    ) internal override {
        UserInfo storage user = users[_msgSender()];
        Deposit memory stakeDeposit = user.deposits[_depositId];
        require(
            stakeDeposit.lockedFrom == 0 ||
                block.timestamp >= stakeDeposit.lockedUntil,
            "Deposit not yet unlocked"
        );

        super._unstake(_user, _depositId, _amount);
    }
}
