// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma experimental ABIEncoderV2;

import '@openzeppelin/contracts/utils/Address.sol';
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./../owner/Auth.sol";
import "./../interface/IFundraising.sol";

contract CheersLpPool is Auth {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address private _mortgageLp;
    address private _cheers;
    address private _feeAddress;

    uint256 public constant DURATION = 90 days;
    uint256 public punishTime = 7 days;
    uint8 public feeRatio = 10;
    uint256 public miningOutput = 1157407407407407;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public lastUpdateTime;
    uint256 public totalPower;
    uint256 public intervalReward;

    address[] public associationPool;
    mapping(address => uint256) public poolIndex;

    mapping(address => uint256) public power;
    mapping(address => uint256) public userLastIntervalReward;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public lastStakedTime;

    event Stake(address indexed user, uint256 amount);

    event Withdraw(address indexed user, uint256 amount, uint256 fee);

    event ReceiveRewards(address indexed user, uint256 amount);

    constructor(
        address _mortgageLpAddress,
        address _cheersAddress,
        address _chargeAddress,
        uint256 _time
    ) public {
        _mortgageLp = _mortgageLpAddress;
        _cheers = _cheersAddress;
        _feeAddress = _chargeAddress;
        startTime = _time;
        endTime = _time + DURATION;
    }

    modifier updateReward(address _account) {
        intervalReward = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (_account != address(0)) {
            rewards[_account] = earned(_account);
            userLastIntervalReward[_account] = intervalReward;
        }
        _;
    }

    modifier checkStart() {
        require(block.timestamp >= startTime, "not start");
        _;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, endTime);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalPower == 0) {
            return intervalReward;
        }
        return intervalReward.add(
            lastTimeRewardApplicable()
            .sub(lastUpdateTime)
            .mul(miningOutput)
            .mul(1e18)
            .div(totalPower)
        );
    }

    function earned(address _account) public view returns (uint256) {
        return
        power[_account]
        .mul(rewardPerToken().sub(userLastIntervalReward[_account]))
        .div(1e18)
        .add(rewards[_account]);
    }

    function stake(uint256 _amount) public checkStart updateReward(msg.sender) {
        require(_amount > 0, "Mortgage amount cannot be zero!");

        lastStakedTime[msg.sender] = block.timestamp;

        totalPower = totalPower.add(_amount);
        power[msg.sender] = power[msg.sender].add(_amount);

        for (uint256 i = 0; i < associationPool.length; i ++) {
            if (power[msg.sender] >= IFundraising(associationPool[i]).getThreshold()) {
                uint8 rank = IFundraising(associationPool[i]).isWhiteList(msg.sender);
                if (rank == 0) {
                    IFundraising(associationPool[i]).setWhiteList(msg.sender, 1);
                }
            }
        }

        IERC20(_mortgageLp).transferFrom(msg.sender, address(this), _amount);

        emit Stake(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) public updateReward(msg.sender) {
        require(_amount > 0, "Redemption quantity cannot be zero!");
        require(_amount <= power[msg.sender], "The redemption amount cannot exceed the mortgage amount!");

        totalPower = totalPower.sub(_amount);
        power[msg.sender] = power[msg.sender].sub(_amount);

        for (uint256 i = 0; i < associationPool.length; i ++) {
            if (power[msg.sender] < IFundraising(associationPool[i]).getThreshold()) {
                uint8 rank = IFundraising(associationPool[i]).isWhiteList(msg.sender);
                if (rank != 2) {
                    IFundraising(associationPool[i]).setWhiteList(msg.sender, 0);
                }
            }
        }

        uint256 fee = 0;
        if (block.timestamp < (lastStakedTime[msg.sender] + punishTime)) {
            fee = _amount.mul(feeRatio).div(100);
            _amount = _amount.sub(fee);
            IERC20(_mortgageLp).transfer(_feeAddress, fee);
        }

        IERC20(_mortgageLp).transfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _amount, fee);
    }

    function receiveRewards() public updateReward(msg.sender) {
        uint256 reward = earned(msg.sender);
        if (reward > 0) {
            rewards[msg.sender] = 0;
            IERC20(_cheers).transfer(msg.sender, reward);
        } else {
            reward = 0;
        }
        emit ReceiveRewards(msg.sender, reward);
    }

    function addAssociationPool(address _addPool) public onlyOperator {
        require(_addPool != address(0), "Pool address can not be 0x0!");
        require(Address.isContract(_addPool), "Must be a contract address");

        uint256 index = associationPool.length;
        poolIndex[_addPool] = index;
        associationPool.push(_addPool);
    }

    function deleteAssociationPool(address _delPool) public onlyOperator {
        require(_delPool != address(0), "Pool address can not be 0x0!");
        require(Address.isContract(_delPool), "Must be a contract address");

        uint256 length = associationPool.length;
        uint256 index = poolIndex[_delPool];

        require(associationPool[index] == _delPool, "Address does not exist!");

        if (index != length.sub(1)) {
            associationPool[index] = associationPool[length.sub(1)];
            poolIndex[associationPool[index]] = index;
        }
        associationPool.pop();
        poolIndex[_delPool] = 0;
    }

    function updateMortgageLp(address _mortgageLpAddress) public onlyOperator {
        _mortgageLp = _mortgageLpAddress;
    }

    function updateFeeAddress(address _fee) public onlyOperator {
        _feeAddress = _fee;
    }

    function updateStartTime(uint256 _time) public onlyOperator {
        startTime = _time;
    }

    function updateEndTime(uint256 _time) public onlyOperator {
        endTime = _time;
    }

    function updateMiningOutput(uint256 _yield) public onlyOperator {
        intervalReward = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        miningOutput = _yield;
    }

    function setWithDrawPunishTime(uint256 _time) public onlyOperator {
        punishTime = _time;
    }

    function setFeeRatio(uint8 _feeRatio) public onlyOperator {
        feeRatio = _feeRatio;
    }

    function getMortgageNum(address _account) public view returns (uint256) {
        return power[_account];
    }

    function isMortgage(address _account) public view returns (bool) {
        return power[_account] > 0;
    }

    function isStart() public view returns (bool) {
        return block.timestamp >= startTime;
    }

    function getDailyReward() public view returns (uint256) {
        return miningOutput * 1 days;
    }

    function getUserPunishTime(address _account) public view returns (uint) {
        if (lastStakedTime[_account] <= 0) {
            return 0;
        }
        if (lastStakedTime[_account].add(punishTime) <= block.timestamp) {
            return 0;
        }
        return lastStakedTime[_account].add(punishTime);
    }

    function remainingTime() public view returns (uint256) {
        if (endTime > 0 && block.timestamp <= endTime) {
            return endTime.sub(block.timestamp);
        } else {
            return 0;
        }
    }

    function balanceOfByUser(address _account) public view returns (uint, uint) {
        return (IERC20(_cheers).balanceOf(_account), IERC20(_mortgageLp).balanceOf(_account));
    }

}
