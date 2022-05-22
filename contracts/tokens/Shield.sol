// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IVeDEG} from "../governance/interfaces/IVeDEG.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title Shield Token (Derived Stablecoin on Degis)
 */
contract Shield is ERC20Upgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    // PTP USD Pool to be used for swapping stablecoins
    address public constant PTPPOOL =
        0x66357dCaCe80431aee0A7507e2E361B7e2402370;

    // USDC address as base token
    address public constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

    IVeDEG veDEG;

    struct Stablecoin {
        bool isSupported;
        uint256 collateralRatio;
    }

    // stablecoin => whether supported
    mapping(address => bool) supportedStablecoin;

    // stablecoin => collteral ratio
    mapping(address => uint256) depositRatio;

    mapping(address => uint256) public users;

    event AddStablecoin(address stablecoin, uint256 collateralRatio);
    event Deposit(address indexed user, uint256 inAmount, uint256 outAmount);
    event Withdraw(address indexed user, uint256 amount);

    function initialize(address _veDEG) public initializer {
        __ERC20_init("Shield Token", "SHD");
        __Ownable_init();

        veDEG = IVeDEG(_veDEG);

        // USDT.e
        supportedStablecoin[0xc7198437980c041c805A1EDcbA50c1Ce5db95118] = true;
        // USDT
        supportedStablecoin[0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7] = true;
        // USDC.e
        supportedStablecoin[0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664] = true;
        // USDC
        supportedStablecoin[USDC] = true;
    }

    /**
     * @notice Add new stablecoin
     * @param _stablecoin Stablecoin address
     * @param _ratio Collateral ratio
     */
    function addSupportedStablecoin(address _stablecoin, uint256 _ratio)
        external
        onlyOwner
    {
        require(_ratio >= 100, "Deposit ratio must be greater than 100");
        supportedStablecoin[_stablecoin] = true;
        depositRatio[_stablecoin] = _ratio;

        emit AddStablecoin(_stablecoin, _ratio);
    }

    function _getDiscount() internal view returns (uint256) {
        uint256 balance = veDEG.balanceOf(msg.sender);
        return balance;
    }

    function deposit(
        address _stablecoin,
        uint256 _amount,
        uint256 _minAmount
    ) external {
        require(supportedStablecoin[_stablecoin], "Stablecoin not supported");

        // Actual shield amount
        uint256 outAmount;

        // Transfer stablecoin to this contract
        // Transfer to this, no need for safeTransferFrom
        IERC20(_stablecoin).transferFrom(msg.sender, address(this), _amount);

        if (_stablecoin != USDC) {
            // Swap stablecoin to USDC and directly goes to this contract
            outAmount = _swap(
                _stablecoin,
                USDC,
                _amount,
                _minAmount,
                address(this),
                block.timestamp + 60
            );
        } else {
            outAmount = _amount;
        }

        // Record user balance
        users[msg.sender] += outAmount;

        // Mint shield
        _mint(msg.sender, outAmount);

        emit Deposit(msg.sender, _amount, outAmount);
    }

    function withdraw(uint256 _amount) public {
        require(users[msg.sender] >= _amount, "Insufficient balance");
        users[msg.sender] -= _amount;

        // Transfer USDC back
        uint256 realAmount = _safeTokenTransfer(USDC, _amount);

        // Burn shield token
        _burn(msg.sender, realAmount);

        emit Withdraw(msg.sender, realAmount);
    }

    /**
     * @notice Withdraw all shield
     */
    function withdrawAll() external {
        require(users[msg.sender] > 0, "Insufficient balance");
        withdraw(users[msg.sender]);
    }

    /**
     * @notice Swap stablecoin to USDC in PTP
     */
    function _swap(
        address _fromToken,
        address _toToken,
        uint256 _fromAmount,
        uint256 _minToAmount,
        address _to,
        uint256 _deadline
    ) internal returns (uint256) {
        bytes memory data = abi.encodeWithSignature(
            "swap(address,address,uint256,uint256,address,uint256)",
            _fromToken,
            _toToken,
            _fromAmount,
            _minToAmount,
            _to,
            _deadline
        );

        (bool success, bytes memory res) = PTPPOOL.call(data);

        require(success, "PTP swap failed");

        (uint256 actualAmount, ) = abi.decode(res, (uint256, uint256));

        return actualAmount;
    }

    function _safeTokenTransfer(address _token, uint256 _amount)
        internal
        returns (uint256 realAmount)
    {
        uint256 balance = IERC20(_token).balanceOf(address(this));

        if (balance > _amount) {
            realAmount = _amount;
        } else {
            realAmount = balance;
        }
        IERC20(_token).safeTransfer(msg.sender, realAmount);
    }
}
