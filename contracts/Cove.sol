pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/ITreasury.sol";

contract TridentWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public trident;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function stake(uint256 amount) public virtual {
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        trident.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public virtual {
        uint256 masonShare = _balances[msg.sender];
        require(masonShare >= amount, "Cove: withdraw request greater than staked amount");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = masonShare.sub(amount);
        trident.safeTransfer(msg.sender, amount);
    }
}

contract Cove is TridentWrapper, ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct Masonseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct CoveSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    IERC20 public argo;
    ITreasury public treasury;

    mapping(address => Masonseat) public masons;
    CoveSnapshot[] public coveHistory;

    uint256 public withdrawLockupEpochs;
    uint256 public rewardLockupEpochs;

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);

    /* ========== Modifiers =============== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Cove: caller is not the operator");
        _;
    }

    modifier masonExists {
        require(balanceOf(msg.sender) > 0, "Cove: The mason does not exist");
        _;
    }

    modifier updateReward(address mason) {
        if (mason != address(0)) {
            Masonseat memory seat = masons[mason];
            seat.rewardEarned = earned(mason);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            masons[mason] = seat;
        }
        _;
    }

    modifier notInitialized {
        require(!initialized, "Cove: already initialized");
        _;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        IERC20 _argo,
        IERC20 _trident,
        ITreasury _treasury
    ) public notInitialized {
        argo = _argo;
        trident = _trident;
        treasury = _treasury;

        CoveSnapshot memory genesisSnapshot = CoveSnapshot({time : block.number, rewardReceived : 0, rewardPerShare : 0});
        coveHistory.push(genesisSnapshot);

        withdrawLockupEpochs = 2; // Lock for 2 epochs (36h) before release withdraw
        rewardLockupEpochs = 1; // Lock for 1 epochs (18h) before release claimReward

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        require(_withdrawLockupEpochs >= _rewardLockupEpochs && _withdrawLockupEpochs <= 56, "_withdrawLockupEpochs: out of range"); // <= 2 week
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters

    function latestSnapshotIndex() public view returns (uint256) {
        return coveHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (CoveSnapshot memory) {
        return coveHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address mason) public view returns (uint256) {
        return masons[mason].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address mason) internal view returns (CoveSnapshot memory) {
        return coveHistory[getLastSnapshotIndexOf(mason)];
    }

    function canWithdraw(address mason) external view returns (bool) {
        return masons[mason].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch();
    }

    function canClaimReward(address mason) external view returns (bool) {
        return masons[mason].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch();
    }

    function epoch() external view returns (uint256) {
        return treasury.epoch();
    }

    function nextEpochPoint() external view returns (uint256) {
        return treasury.nextEpochPoint();
    }

    function getARGOPrice() external view returns (uint256) {
        return treasury.getARGOPrice();
    }

    // =========== Mason getters

    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address mason) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(mason).rewardPerShare;

        return balanceOf(mason).mul(latestRPS.sub(storedRPS)).div(1e18).add(masons[mason].rewardEarned);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) public override onlyOneBlock updateReward(msg.sender) {
        require(amount > 0, "Cove: Cannot stake 0");
        super.stake(amount);
        masons[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override onlyOneBlock masonExists updateReward(msg.sender) {
        require(amount > 0, "Cove: Cannot withdraw 0");
        require(masons[msg.sender].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch(), "Cove: still in withdraw lockup");
        claimReward();
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
    }

    function claimReward() public updateReward(msg.sender) {
        uint256 reward = masons[msg.sender].rewardEarned;
        if (reward > 0) {
            require(masons[msg.sender].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch(), "Cove: still in reward lockup");
            masons[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
            masons[msg.sender].rewardEarned = 0;
            argo.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function allocateSeigniorage(uint256 amount) external onlyOneBlock onlyOperator {
        require(amount > 0, "Cove: Cannot allocate 0");
        require(totalSupply() > 0, "Cove: Cannot allocate when totalSupply is 0");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));

        CoveSnapshot memory newSnapshot = CoveSnapshot({
            time: block.number,
            rewardReceived: amount,
            rewardPerShare: nextRPS
        });
        coveHistory.push(newSnapshot);

        argo.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardAdded(msg.sender, amount);
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(argo), "argo");
        require(address(_token) != address(trident), "trident");
        _token.safeTransfer(_to, _amount);
    }
}