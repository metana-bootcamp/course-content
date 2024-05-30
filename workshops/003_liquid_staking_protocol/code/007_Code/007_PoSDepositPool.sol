// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.13;

import {MetanaEth} from "./MetanaEth.sol";
import {AutoMetanaEth} from "./AutoMetanaEth.sol";
import {ValidatorQueue} from "./ValidatorQueue.sol";
import {DataTypes} from "./DataTypes.sol";
import {Errors} from "./Errors.sol";
import {Ownable2Step} from "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/c80b675b8db1d951b8b3734df59530d0d3be064b/contracts/access/Ownable2Step.sol";
import {Ownable} from "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/c80b675b8db1d951b8b3734df59530d0d3be064b/contracts/access/Ownable.sol";
import {MetanaSemiFungible} from "./MetanaSemiFungible.sol";

interface IDeposit {
    function deposit(
        bytes calldata pubkey,
        bytes calldata withdrawal_credentials,
        bytes calldata signature,
        bytes32 deposit_data_root
    ) external payable;
}

contract PoSDepositPool is Ownable2Step {
    using ValidatorQueue for DataTypes.ValidatorDeque;

    DataTypes.ValidatorDeque internal initializedValidators;

    DataTypes.ValidatorDeque internal stakingValidators;

    IDeposit public immutable beaconchainDepositContract;

    uint256 public immutable beaconChainDepositAmount;

    uint256 public pendingDeposit;

    uint256 public pendingWithdrawals;

    uint256 public pendingRedemptions;

    MetanaEth public immutable metanaEth;

    AutoMetanaEth public immutable autoMetanaEth;

    address public immutable rewardWithdrawer;

    MetanaSemiFungible public immutable metanaSemiFungible;

    uint256 public batchId;

    uint256 public maxProcessedValidatorCount = 20;

    mapping(uint256 => DataTypes.Validator) public unstakedValidators;

    mapping(bytes => DataTypes.ValidatorStatus) public validatorStatuses;

    event VoluntaryExit(bytes pubKey);
    event DissolveValidator(bytes pubKey);

    constructor(
        address _defaultAdmin,
        address _beaconchainDepositContract,
        uint256 _beaconChainDepositAmount,
        address _metanaEth,
        address _autoMetanaEth,
        address _rewardWithdrawer
    ) Ownable(_defaultAdmin) {
        if (_beaconchainDepositContract == address(0))
            revert Errors.ZeroAddress();
        if (_metanaEth == address(0)) revert Errors.ZeroAddress();
        if (_autoMetanaEth == address(0)) revert Errors.ZeroAddress();
        if (_rewardWithdrawer == address(0)) revert Errors.ZeroAddress();
        if (
            _beaconChainDepositAmount < 1 ether ||
            _beaconChainDepositAmount % 1 gwei != 0
        ) revert Errors.InvalidBeaconChainDepositValue();

        beaconchainDepositContract = IDeposit(_beaconchainDepositContract);
        beaconChainDepositAmount = _beaconChainDepositAmount;
        metanaEth = MetanaEth(_metanaEth);
        autoMetanaEth = AutoMetanaEth(_autoMetanaEth);
        rewardWithdrawer = _rewardWithdrawer;
    }

    function setMaxProcessedValidatorCount(uint256 _maxProcessedValidatorCount)
        external
        onlyOwner
    {
        maxProcessedValidatorCount = _maxProcessedValidatorCount;
    }

    function deposit(address _receiver, bool _allowBeaconChainDeposit)
        external
        payable
    {
        uint256 _amount = msg.value;
        if (_amount == 0) revert Errors.ZeroAmount();
        if (_receiver == address(0)) revert Errors.ZeroAddress();

        pendingDeposit += _amount;
        if (_allowBeaconChainDeposit) {
            _stake();
        }
        metanaEth.mint(address(this), _amount);
        metanaEth.approve(address(autoMetanaEth), _amount);
        autoMetanaEth.deposit(_amount, _receiver);
    }

    function addAddInitializedValidator(DataTypes.Validator memory _validator)
        external
        onlyOwner
    {
        initializedValidators.add(_validator);
    }

    function depositPrivilege() external onlyOwner {
        _stake();
    }

    function _stake() private {
        uint256 _remainingCount = maxProcessedValidatorCount;
        while (
            initializedValidators.count() != 0 &&
            pendingDeposit >= beaconChainDepositAmount &&
            _remainingCount > 0
        ) {
            DataTypes.Validator memory _validator = initializedValidators
                .getNext();

            if (
                validatorStatuses[_validator.pubKey] !=
                DataTypes.ValidatorStatus.None
            ) revert Errors.NoUsedValidator();

            beaconchainDepositContract.deposit{value: beaconChainDepositAmount}(
                _validator.pubKey,
                _validator.withdrawal_credentials,
                _validator.signature,
                _validator.depositDataRoot
            );
            validatorStatuses[_validator.pubKey] = DataTypes
                .ValidatorStatus
                .Staking;
            pendingDeposit -= beaconChainDepositAmount;
            stakingValidators.add(_validator);
            _remainingCount--;
        }
    }

    function harvest() external payable {
        if (msg.sender != rewardWithdrawer) revert Errors.Unauthorized();
        uint256 _rewards = msg.value;
        pendingDeposit += _rewards;
        metanaEth.mint(address(autoMetanaEth), _rewards);
        autoMetanaEth.notifyRewardAmount();
        _stake();
    }

    function initiateUnstaking(uint256 _shares, address _receiver) external {
        if (_shares == 0) revert Errors.ZeroAmount();
        if (_receiver == address(0)) revert Errors.ZeroAddress();

        autoMetanaEth.transferFrom(msg.sender, address(this), _shares);
        uint256 _assets = autoMetanaEth.redeem(
            _shares,
            address(this),
            address(this)
        );
        uint256 _requiredValidators = (pendingWithdrawals + _assets) /
            beaconChainDepositAmount;
        uint256 _stakingValidatorCount = stakingValidators.count();
        if (_requiredValidators > _stakingValidatorCount)
            revert Errors.NotEnoughValidators();

        metanaEth.burn(address(this), _assets);
        _initiateUnstaking(_assets, _receiver);
    }

    function _initiateUnstaking(uint256 _assets, address _receiver) internal {
        pendingWithdrawals += _assets;
        while (pendingWithdrawals / beaconChainDepositAmount != 0) {
            uint256 _allocationPossible = beaconChainDepositAmount +
                _assets -
                pendingWithdrawals;
            metanaSemiFungible.mint(_receiver, batchId, _allocationPossible);
            DataTypes.Validator memory _validator = stakingValidators.getNext();

            unstakedValidators[batchId] = _validator;
            emit VoluntaryExit(_validator.pubKey);
            validatorStatuses[_validator.pubKey] = DataTypes
                .ValidatorStatus
                .Withdrawable;

            pendingWithdrawals -= beaconChainDepositAmount;
            _assets -= _allocationPossible;
            batchId++;
        }
        if (_assets > 0) {
            metanaSemiFungible.mint(_receiver, batchId, _assets);
        }
    }

    function dissolveValidator(bytes memory _publicKey) external payable {
        if (msg.sender != rewardWithdrawer) revert Errors.Unauthorized();
        if (
            validatorStatuses[_publicKey] !=
            DataTypes.ValidatorStatus.Withdrawable
        ) revert Errors.NotWithdrawable();
        uint256 _amount = msg.value;
        if (_amount != beaconChainDepositAmount) revert Errors.InvalidAmount();
        pendingRedemptions += _amount;
        validatorStatuses[_publicKey] = DataTypes.ValidatorStatus.Dissolved;
        emit DissolveValidator(_publicKey);
    }

    function redeem(
        uint256 _tokenId,
        uint256 _assets,
        address _receiver
    ) external {
        DataTypes.Validator memory _validator = unstakedValidators[_tokenId];

        if (
            validatorStatuses[_validator.pubKey] !=
            DataTypes.ValidatorStatus.Dissolved
        ) revert Errors.StatusNotDissolved(_validator.pubKey);

        metanaSemiFungible.burn(msg.sender, _tokenId, _assets);
        pendingRedemptions -= _assets;

        (bool ok, ) = payable(_receiver).call{value: _assets}("");
        require(ok);
    }
}
