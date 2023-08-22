// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

interface IWhiteList {
    function isInWhiteList(address account) external view returns (bool);
}

contract CoinbaseLaunchpadPool is AccessControl {
    using SafeMath for uint256;

    uint256 private startTime;
    uint256 private endTime;
    uint256 private totalSupply;
    uint256 private totalLaunchpadAmount;
    address private IDOTokenAddress;

    address private txnTokenAddress;
    uint256 private txnRatio;

    mapping(address => BuyRecord) public mBuyRecords;
    address[] private aryAccounts;

    TxnLimit private buyLimit;
    uint256 private whiteListExpireTime = 0;
    address private whiteListContract;

    ReleaseRule[] private aryReleaseRules;

    bool private claimOpen = false;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    address private newOwnerAddress = 0x8d0448e8a76C590986eD069691EAD64a54e3257F;
    address private operatorAddress = 0x0CA22A87967e2A91Ff9cAC5fFdcf8ad37d2DcCe2;

    constructor(
        uint256 _startTime,
        uint256 _duration,
        uint256 _totalSupply,
        address _IDOTokenAddress,
        address _txnTokenAddress,
        uint256 _txnRatio
    ) {
        startTime = _startTime;
        endTime = _startTime + _duration;
        totalSupply = 0;
        totalLaunchpadAmount = _totalSupply;

        IDOTokenAddress = _IDOTokenAddress;
        txnTokenAddress = _txnTokenAddress;
        txnRatio = _txnRatio;
        buyLimit.maxTimes = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, newOwnerAddress);
        _grantRole(MANAGER_ROLE, operatorAddress);
    }

    function getPoolInfo() public view returns (PoolInfo memory) {
        PoolInfo memory poolInfo = PoolInfo({
            withdrawToken : IDOTokenAddress,
            exchangeToken : txnTokenAddress,
            ratio : txnRatio,
            poolStartTime : startTime,
            poolEndTime : endTime,
            total : totalLaunchpadAmount
        });
        return poolInfo;
    }

    struct PoolInfo {
        address withdrawToken;
        address exchangeToken;
        uint256 ratio;
        uint256 poolStartTime;
        uint256 poolEndTime;
        uint256 total;
    }

    function getEndTime() public view returns (uint256) {
        return endTime;
    }

    function getBuyRecord(address account) public view returns (BuyRecord memory record) {
        record = mBuyRecords[account];
        (uint256 txnNowBalance, uint256 txnBalance) = balanceOfTxnToken();

        if (txnNowBalance > txnBalance) {.
            record.rewards = totalLaunchpadAmount * record.txnAmount / txnNowBalance;
        }
    }

    function getAccountsLength() public view returns (uint256) {
        return aryAccounts.length;
    }

    function getBuyRecordByIndex(uint256 index) public view returns (BuyRecord memory record) {
        record = mBuyRecords[aryAccounts[index]];
        (uint256 txnNowBalance, uint256 txnBalance) = balanceOfTxnToken();
        if (txnNowBalance > txnBalance) {
            record.rewards = totalLaunchpadAmount * record.txnAmount / txnNowBalance;
        }
    }

    function purchase(uint256 txnAmount) public payable {
        require(block.timestamp >= startTime, "this pool is not start");
        require(block.timestamp <= endTime, "this pool is end");

        if (txnTokenAddress == address(0)) {
            require(msg.value == txnAmount);
        }
        if (whiteListContract != address(0) && (whiteListExpireTime == 0 || block.timestamp < whiteListExpireTime)) {
            require(IWhiteList(whiteListContract).isInWhiteList(msg.sender), "you is not in white list");
        }
        if (buyLimit.minAmount > 0) {
            require(txnAmount >= buyLimit.minAmount, "buy amount too small");
        }
        if (buyLimit.maxAmount > 0) {
            require(txnAmount <= buyLimit.maxAmount, "buy amount too large");
        }
        if (buyLimit.maxTimes > 0) {
            require(mBuyRecords[msg.sender].buyTimes < buyLimit.maxTimes, "buy times is not enough");
        }

        uint256 rewards = 0;
        if (txnTokenAddress != address(0)) {
            uint256 txnDecimals = IERC20Metadata(txnTokenAddress).decimals();
            rewards = txnAmount.mul(txnRatio).div(10 ** txnDecimals);
            TransferHelper.safeTransferFrom(txnTokenAddress, msg.sender, address(this), txnAmount);
        } else {
            rewards = txnAmount.mul(txnRatio).div(10 ** 18);
        }
        require(rewards > 0, "txn amount is too small");

        totalSupply += rewards;

        if (mBuyRecords[msg.sender].buyTimes == 0) {
            aryAccounts.push(msg.sender);
        }
        mBuyRecords[msg.sender].buyTimes += 1;
        mBuyRecords[msg.sender].txnAmount += txnAmount;
        mBuyRecords[msg.sender].rewards += rewards;
    }

    function earned(address account) public view returns (uint256) {
        uint256 totalTxnAmount = 0;
        if (txnTokenAddress == address(0)) {
            totalTxnAmount = address(this).balance;
        } else {
            totalTxnAmount = IERC20(txnTokenAddress).balanceOf(address(this));
        }

        uint256 releaseRewards = 0;
        if (block.timestamp > endTime) {
            uint256 calcRatio = 0;
            BuyRecord memory record = getBuyRecord(account);

            if (aryReleaseRules.length > 0) {
                for (uint256 idx = 0; idx < aryReleaseRules.length; idx++) {
                    ReleaseRule memory rule = aryReleaseRules[idx];
                    if (block.timestamp > rule.iTime) {
                        calcRatio += rule.ratio;
                    }
                }
            } else {
                calcRatio = 1e18;
            }

            releaseRewards = record.rewards.mul(calcRatio).div(1e18).sub(record.paidRewards);
            uint256 surplusRewards = IERC20(IDOTokenAddress).balanceOf(address(this));
            releaseRewards = Math.min(releaseRewards, surplusRewards);
        }
        return releaseRewards;
    }

    function claimRewards() public {
        require(claimOpen, "can not claim now");
        require(block.timestamp > endTime, "this pool is not end");

        uint256 totalTxnAmount = 0;
        if (txnTokenAddress == address(0)) {
            totalTxnAmount = address(this).balance;
        } else {
            totalTxnAmount = IERC20(txnTokenAddress).balanceOf(address(this));
        }

        uint256 trueRewards = earned(msg.sender);
        require(trueRewards > 0, "rewards amount can not be zero");
        TransferHelper.safeTransfer(IDOTokenAddress, msg.sender, trueRewards);
        mBuyRecords[msg.sender].paidRewards += trueRewards;
    }

    function withdraw(address tokenAddress, address account, uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        TransferHelper.safeTransfer(tokenAddress, account, amount);
    }

    function withdrawETH(address account, uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        payable(account).transfer(amount);
    }

    function setClaimOpen(bool _claimOpen) public onlyRole(MANAGER_ROLE) {
        claimOpen = _claimOpen;
    }

    function getClaimOpen() public view returns (bool) {
        return claimOpen;
    }

    function getTotalSupply() public view returns (uint256) {
        return totalSupply;
    }

    function setTxnLimit(
        uint256 _maxTimes,
        uint256 _minAmount,
        uint256 _maxAmount
    ) public onlyRole(MANAGER_ROLE) {
        buyLimit.maxTimes = _maxTimes;
        buyLimit.minAmount = _minAmount;
        buyLimit.maxAmount = _maxAmount;
    }

    function checkTxnLimit() public view returns (TxnLimit memory){
        return buyLimit;
    }

    function setWhiteListInfo(
        address _contractAddress,
        uint256 _expireTime
    ) public onlyRole(MANAGER_ROLE) {
        whiteListContract = _contractAddress;
        whiteListExpireTime = _expireTime;
    }

    function checkWhiteListInfo() public view returns (address _contractAddress, uint256 _expireTime) {
        _contractAddress = whiteListContract;
        _expireTime = whiteListExpireTime;
    }

    function setReleaseRules(
        uint256[] calldata aryTime,
        uint256[] calldata aryRatio
    ) public onlyRole(MANAGER_ROLE) {
        require(aryTime.length == aryRatio.length, "length must be equal");

        uint256 aryLength = aryTime.length;
        uint256 totalReleaseRatio = 0;
        for (uint256 idx = 0; idx < aryLength; idx++) {
            totalReleaseRatio += aryRatio[idx];
        }
        require(totalReleaseRatio == 1e18, "total ratio must be equal to 1e18");
        delete aryReleaseRules;
        for (uint256 idx = 0; idx < aryLength; idx++) {
            ReleaseRule memory _rule = ReleaseRule({
                iTime : aryTime[idx],
                ratio : aryRatio[idx]
            });
            aryReleaseRules.push(_rule);
        }
    }

    function checkReleaseRules() public view returns (ReleaseRule[] memory) {
        return aryReleaseRules;
    }

    function resetEndTime(uint256 _endTime) public onlyRole(MANAGER_ROLE) {
        endTime = _endTime;
    }

    function balanceOfTxnToken() public view returns (uint256, uint256) {
        if (txnTokenAddress == address(0)) {
            return (address(this).balance, 1e18 * totalLaunchpadAmount / txnRatio);
        } else {
            uint256 txnDecimals = IERC20Metadata(txnTokenAddress).decimals();
            return (IERC20(txnTokenAddress).balanceOf(address(this)), 10 ** txnDecimals * totalLaunchpadAmount / txnRatio);
        }
    }

    struct BuyRecord {
        uint256 buyTimes;
        uint256 txnAmount;
        uint256 rewards;
        uint256 paidRewards;
    }

    struct ReleaseRule {
        uint256 iTime;
        uint256 ratio;
    }

    struct TxnLimit {
        uint256 maxTimes;
        uint256 minAmount;
        uint256 maxAmount;
    }
}
