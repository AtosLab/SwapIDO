pragma solidity 0.6.2;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/Math.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/Address.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/Arrays.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/AccessControl.sol";

contract CatDAOContract is Initializable, ContextUpgradeSafe, AccessControlUpgradeSafe, PausableUpgradeSafe, ReentrancyGuardUpgradeSafe {

  using SafeMath for uint256;
  using Math for uint256;
  using Address for address;
  using Arrays for uint256[];

  bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
  bytes32 private constant OWNER_ROLE = keccak256("OWNER_ROLE");
  bytes32 private constant REWARDS_DISTRIBUTOR_ROLE = keccak256("REWARDS_DISTRIBUTOR_ROLE");

  // EVENTS
  event TokenDeposited(address indexed account, uint256 amount);
  event WithdrawInitiated(address indexed account, uint256 amount);
  event WithdrawExecuted(address indexed account, uint256 amount, uint256 reward);
  event RewardsDistributed(uint256 amount);

  // STRUCT DECLARATIONS
  struct TokenDeposit {
    uint256 amount;
    uint256 startDate;
    uint256 endDate;
    uint256 entryRewardPoints;
    uint256 exitRewardPoints;
    bool exists;
  }

  // CONTRACT STATE VARIABLES
  IERC20 public token;
  address public rewardsAddress;
  uint256 public maxTokenAmount;
  uint256 public currentTotalStake;
  uint256 public releasePeriod;

  //reward calculations
  uint256 private totalRewardPoints;
  uint256 public rewardsDistributed;
  uint256 public rewardsWithdrawn;
  uint256 public totalRewardsDistributed;

  mapping(address => TokenDeposit) private _tokenDeposits;

  // MODIFIERS
  modifier guardMaxTokenLimit(uint256 amount)
  {
    uint256 resultedStakedAmount = currentTotalStake.add(amount);
    require(resultedStakedAmount <= maxTokenAmount, "[Deposit] Your deposit would exceed the current token limit");
    _;
  }

  modifier onlyContract(address account)
  {
    require(account.isContract(), "[Validation] The address does not contain a contract");
    _;
  }

  // PUBLIC FUNCTIONS
  function initialize(address _token, address _rewardsAddress, uint256 _maxTokenAmount, uint256 _releasePeriod)
  public
  onlyContract(_token)
  {
    __CatDAOContract_init(_token, _rewardsAddress, _maxTokenAmount, _releasePeriod);
  }

  function __CatDAOContract_init(address _token, address _rewardsAddress, uint256 _maxTokenAmount, uint256 _releasePeriod)
  internal
  initializer
  {
    require(
      _token != address(0),
      "[Validation] Invalid swap token address"
    );
    require(_maxTokenAmount > 0, "[Validation] _maxTokenAmount has to be larger than 0");
    __Context_init_unchained();
    __AccessControl_init_unchained();
    __Pausable_init_unchained();
    __ReentrancyGuard_init_unchained();
    __CatDAOContract_init_unchained();

    pause();
    setRewardAddress(_rewardsAddress);
    unpause();

    token = IERC20(_token);
    maxTokenAmount = _maxTokenAmount;
    releasePeriod = _releasePeriod;
  }

  function __CatDAOContract_init_unchained()
  internal
  initializer
  {
    _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
    _setupRole(PAUSER_ROLE, _msgSender());
    _setupRole(OWNER_ROLE, _msgSender());
    _setupRole(REWARDS_DISTRIBUTOR_ROLE, _msgSender());
  }

  function pause()
  public
  {
    require(hasRole(PAUSER_ROLE, _msgSender()), "CatDAOContract: must have pauser role to pause");
    _pause();
  }

  function unpause()
  public
  {
    require(hasRole(PAUSER_ROLE, _msgSender()), "CatDAOContract: must have pauser role to unpause");
    _unpause();
  }

  function setRewardAddress(address _rewardsAddress)
  public
  whenPaused
  {
    require(hasRole(OWNER_ROLE, _msgSender()), "[Validation] The caller must have owner role to set rewards address");
    require(_rewardsAddress != address(0), "[Validation] _rewardsAddress is the zero address");
    require(_rewardsAddress != rewardsAddress, "[Validation] _rewardsAddress is already set to given address");
    rewardsAddress = _rewardsAddress;
  }

  function setTokenAddress(address _token)
  external
  onlyContract(_token)
  whenPaused
  {
    require(hasRole(OWNER_ROLE, _msgSender()), "[Validation] The caller must have owner role to set token address");
    require(
      _token != address(0),
      "[Validation] Invalid swap token address"
    );
    token = IERC20(_token);
  }

  function deposit(uint256 amount)
  external
  nonReentrant
  whenNotPaused
  guardMaxTokenLimit(amount)
  {
    require(amount > 0, "[Validation] The token deposit has to be larger than 0");
    require(!_tokenDeposits[msg.sender].exists, "[Deposit] You already have a token");

    TokenDeposit storage tokenDeposit = _tokenDeposits[msg.sender];
    tokenDeposit.amount = tokenDeposit.amount.add(amount);
    tokenDeposit.startDate = block.timestamp;
    tokenDeposit.exists = true;
    tokenDeposit.entryRewardPoints = totalRewardPoints;

    currentTotalStake = currentTotalStake.add(amount);

    // Transfer the Tokens to this contract
    require(token.transferFrom(msg.sender, address(this), amount), "[Deposit] Something went wrong during the token transfer");
    emit TokenDeposited(msg.sender, amount);
  }

  function initiateWithdrawal()
  external
  nonReentrant
  whenNotPaused
  {
    TokenDeposit storage tokenDeposit = _tokenDeposits[msg.sender];
    require(tokenDeposit.exists && tokenDeposit.amount != 0, "[Initiate Withdrawal] There is no token deposit for this account");
    require(tokenDeposit.endDate == 0, "[Initiate Withdrawal] You already initiated the withdrawal");

    tokenDeposit.endDate = block.timestamp;
    tokenDeposit.exitRewardPoints = totalRewardPoints;

    currentTotalStake = currentTotalStake.sub(tokenDeposit.amount);

    emit WithdrawInitiated(msg.sender, tokenDeposit.amount);
  }

  function executeWithdrawal()
  external
  nonReentrant
  whenNotPaused
  {
    TokenDeposit memory tokenDeposit = _tokenDeposits[msg.sender];
    require(tokenDeposit.exists && tokenDeposit.amount != 0, "[Withdraw] There is no token deposit for this account");
    require(tokenDeposit.endDate != 0, "[Withdraw] Withdraw is not initialized");

    // validate enough days have passed from initiating the withdrawal
    uint256 daysPassed = (block.timestamp - tokenDeposit.endDate) / 1 days;
    require(releasePeriod <= daysPassed, "[Withdraw] The releasePeriod period did not pass");

    uint256 amount = tokenDeposit.amount;
    uint256 reward = _computeReward(tokenDeposit);

    delete _tokenDeposits[msg.sender];

    //calculate withdrawed rewards in single distribution cycle
    rewardsWithdrawn = rewardsWithdrawn.add(reward);

    require(token.transfer(msg.sender, amount), "[Withdraw] Something went wrong while transferring your initial deposit");
    require(token.transferFrom(rewardsAddress, msg.sender, reward), "[Withdraw] Something went wrong while transferring your reward");

    emit WithdrawExecuted(msg.sender, amount, reward);
  }

  // VIEW FUNCTIONS FOR HELPING THE USER AND CLIENT INTERFACE
  function getStakeDetails(address account)
  external
  view
  returns (uint256 initialDeposit, uint256 startDate, uint256 endDate, uint256 rewards)
  {
    require(_tokenDeposits[account].exists && _tokenDeposits[account].amount != 0, "[Validation] This account doesn't have a token deposit");

    TokenDeposit memory s = _tokenDeposits[account];

    return (s.amount, s.startDate, s.endDate, _computeReward(s));
  }

  function _computeReward(TokenDeposit memory tokenDeposit)
  private
  view
  returns (uint256)
  {
    uint256 rewardsPoints = 0;

    if ( tokenDeposit.endDate == 0 )
    {
      rewardsPoints = totalRewardPoints.sub(tokenDeposit.entryRewardPoints);
    }
    else
    {
      //withdrawal is initiated
      rewardsPoints = tokenDeposit.exitRewardPoints.sub(tokenDeposit.entryRewardPoints);
    }
    return tokenDeposit.amount.mul(rewardsPoints).div(10 ** 18);
  }

  function distributeRewards()
  external
  nonReentrant
  whenNotPaused
  {
    require(hasRole(REWARDS_DISTRIBUTOR_ROLE, _msgSender()),
        "[Validation] The caller must have rewards distributor role");
    _distributeRewards();
  }

  function _distributeRewards()
  private
  whenNotPaused
  {
    require(hasRole(REWARDS_DISTRIBUTOR_ROLE, _msgSender()),
        "[Validation] The caller must have rewards distributor role");
    require(currentTotalStake > 0, "[Validation] not enough total token accumulated");
    uint256 rewardPoolBalance = token.balanceOf(rewardsAddress);
    require(rewardPoolBalance > 0, "[Validation] not enough rewards accumulated");

    uint256 newlyAdded = rewardPoolBalance.add(rewardsWithdrawn).sub(rewardsDistributed);
    uint256 ratio = newlyAdded.mul(10 ** 18).div(currentTotalStake);
    totalRewardPoints = totalRewardPoints.add(ratio);
    rewardsDistributed = rewardPoolBalance;
    rewardsWithdrawn = 0;
    totalRewardsDistributed = totalRewardsDistributed.add(newlyAdded);

    emit RewardsDistributed(newlyAdded);
  }

  function version() public pure returns (string memory) {
    return "v1";
  }
}