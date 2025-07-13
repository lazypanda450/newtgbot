/**
 *Submitted for verification at BscScan.com on 2025-07-12
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IAutoPoolFundV10 {
    function users(address user) external view returns (
        address referrer,
        uint256 totalEarned,
        uint256 directReferrals,
        uint256 lastJoinTime,
        uint256 lastROITime,
        uint256 currentCycleROI,
        uint256 joinCount,
        bool isActive,
        bool reachedTotalLimit
    );
    function userDownlines(address user, uint256 index) external view returns (address);
    function userDownlineCount(address user) external view returns (uint256);
    function userTotalROIClaims(address user) external view returns (uint256);
    function migratedUsersCount() external view returns (uint256);
    function getAllReferrers() external view returns (address[] memory);
    function totalUsers() external view returns (uint256);
    function migratedUsers(uint256 index) external view returns (address);
    function teamSizes(address referrer) external view returns (uint256);
    function teamPools(address referrer, uint256 index) external view returns (address);
}

interface IAutoPoolFundV12 {
    function users(address user) external view returns (
        address referrer,
        uint256 totalEarned,
        uint256 lastJoinTime,
        uint256 lastROITime,
        uint256 joinCount,
        uint256 rejoinCount,
        bool isActive,
        bool reachedTotalLimit,
        uint256 directReferrals
    );
    function userDownlines(address user, uint256 index) external view returns (address);
    function userPendingROI(address user) external view returns (uint256);
    function autopoolPendingBalance(address user) external view returns (uint256);
    function userCombinedProfits(address user) external view returns (uint256);
    function userTotalROIClaims(address user) external view returns (uint256);
    function totalUsers() external view returns (uint256);
    function hasBeenMigrated(address user) external view returns (bool);
    function migratedUsers(uint256 index) external view returns (address);
    function migratedUsersCount() external view returns (uint256);
}

contract AutoPoolFundV11 {
    IERC20 public usdt;
    address public admin;
    bool internal locked;
    IAutoPoolFundV10 private oldAutoPoolFund;
    IAutoPoolFundV12 private oldV12Contract; // For V12 to V12 migration

    // Constants for ROI System
    uint256 public constant ENTRY_FEE = 10 * 1e18; // 10 USDT
    uint256 public constant REJOIN_FEE = 10 * 1e18; // 10 USDT (same as entry)
    uint256 public constant ADMIN_FEE_PER_JOIN = 2 * 1e18; // 2 USDT admin fee
    uint256 public constant ADMIN_FEE_FROM_ENTRY = 2 * 1e18; // 2 USDT admin fee
    uint256 public constant HOURLY_ROI_AMOUNT = 2 * 1e18; // 2 USDT paid every hour automatically
    uint256 public constant ROI_INTERVAL = 1 hours; // 1 hour interval for ROI accumulation
    uint256 public constant MIN_CONTRACT_BALANCE = 200 * 1e18; // Minimum contract balance
    uint256 public constant MIN_TOTAL_DIRECT_REFERRALS = 2; // Min total directs for ROI
    uint256 public constant MIN_ACTIVE_DIRECT_REFERRALS = 1; // Min active directs for ROI

    // === COMBINED PROFIT SYSTEM ===
    uint256 public constant AUTOPOOL_COMMISSION = 5 * 1e18; // 5 USDT per autopool cycle
    uint256 public constant COMBINED_PROFIT_THRESHOLD = 20 * 1e18; // 20 USDT combined profit for rejoin eligibility
    uint256 public constant MAX_PROFIT_CAP = 20 * 1e18; // 20 USDT maximum profit cap - no accumulation beyond this
    uint256 public constant MIN_CLAIM_AMOUNT = 20 * 1e18; // 20 USDT minimum claim (FIXED: was 10 USDT)
    uint256 public constant TEAM_POOL_SIZE = 2; // Binary system
    uint256 public maxAutopoolProcessingPerTx = 5;
    
    // === TEAM-BASED AUTOPOOL MAPPINGS ===
    mapping(address => address[]) public teamAutopoolQueue; // teamLeader => queue
    mapping(address => address) public userTeamLeader; // user => teamLeader
    mapping(address => uint256) public autopoolPendingBalance; // user => pending autopool earnings
    mapping(address => uint256) public autopoolTotalEarned; // user => total autopool earned
    mapping(address => uint256) public autopoolPosition; // user => position in their team pool
    mapping(address => bool) public isAutopoolActive; // user => active in autopool
    
    // === COMBINED PROFIT TRACKING ===
    mapping(address => uint256) public userPendingROI; // Accumulated hourly ROI payments (2 USDT/hour)
    mapping(address => uint256) public userLastROIUpdate; // Last time ROI was calculated
    mapping(address => uint256) public userCombinedProfits; // Total combined profits (ROI + autopool)

    // Migration control
    mapping(address => bool) public hasBeenMigrated;
    bool public migrationCompleted = false;
    uint256 public migratedUsersCount = 0;
    uint256 public totalUsersToMigrate = 0;
    uint256 public migrationCurrentIndex = 0;
    address[] public migratedUsers;

    // User Structure
    struct User {
        address referrer;
        uint256 totalEarned; // Total ROI earned by this user
        uint256 lastJoinTime; // Timestamp of the last join/rejoin
        uint256 lastROITime;  // Timestamp of the last ROI claim
        uint256 joinCount;    // How many times the user has joined (including initial)
        uint256 rejoinCount;  // How many times the user has rejoined
        bool isActive;        // True if eligible to claim ROI in current cycle
        bool reachedTotalLimit; // True if user has claimed max ROI for current cycle and needs to rejoin
        uint256 directReferrals; // Total number of direct referrals
    }

    // Enhanced User Profile for return values
    struct UserProfileInfo {
        address referrer;
        uint256 totalEarned;
        uint256 lastJoinTime;
        bool isActive;
        bool reachedTotalLimit;
        uint256 rejoinCount;
        uint256 requiredActiveDirects;
        uint256 directReferralsCount;
    }

    // Combined Profit Info struct
    struct CombinedProfitInfo {
        uint256 pendingROI;             // Accumulated hourly ROI (2 USDT/hour)
        uint256 autopoolEarnings;       // Autopool earnings (5 USDT per cycle)
        uint256 totalCombinedProfits;   // Sum of both
        uint256 thresholdForRejoin;     // 20 USDT threshold
        bool eligibleForCombinedRejoin; // Can rejoin with combined profits
        uint256 shortfallToThreshold;   // How much more needed
        uint256 availableForClaim;      // Amount available to claim (if >= 10 USDT)
        string status;
    }

    // State Variables
    mapping(address => User) public users;
    mapping(address => uint256) public userTotalROIClaims;
    mapping(address => address[]) public userDownlines;

    uint256 public totalUsers;
    uint256 public totalFundsReceived;
    uint256 public totalPaidOut;
    uint256 public totalCombinedProfitRejoins; // Track combined profit rejoins

    // Events
    event UserJoined(address indexed user, address indexed referrer, uint256 fee);
    event UserRejoined(address indexed user, address indexed referrer, uint256 fee);
    event CombinedProfitRejoin(address indexed user, uint256 roiUsed, uint256 autopoolUsed, uint256 timestamp);
    event HourlyROIAccumulated(address indexed user, uint256 amount, uint256 totalPending, uint256 timestamp);
    event ROIClaimed(address indexed user, uint256 amount);
    event AutopoolPayout(address indexed user, address indexed teamLeader, uint256 amount, uint256 position);
    event AutopoolClaimed(address indexed user, uint256 amount);
    event CombinedProfitsClaimed(address indexed user, uint256 roiAmount, uint256 autopoolAmount, uint256 totalClaimed);
    event CombinedProfitUpdated(address indexed user, uint256 totalCombined, bool thresholdReached);
    event ProfitCapReached(address indexed user, uint256 totalProfits, uint256 timestamp);
    event MigrationStarted(uint256 totalUsers, uint256 timestamp);
    event MigrationCompleted(uint256 totalMigratedUsers, uint256 timestamp);
    event MigrationBatchCompleted(uint256 batchSize, uint256 currentIndex, uint256 timestamp);

    modifier noReentrant() {
        require(!locked, "No re-entrancy");
        locked = true;
        _;
        locked = false;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    modifier migrationCompleteOnly() {
        require(migrationCompleted, "Migration in progress");
        _;
    }

    constructor() {
        usdt = IERC20(0x55d398326f99059fF775485246999027B3197955); // USDT (BSC)
        admin = 0x3Da7310861fbBdf5105ea6963A2C39d0Cb34a4Ff; // Admin address
        oldAutoPoolFund = IAutoPoolFundV10(0x95C2346Cc87Ae5919F12a0f12E989a8e6dc3613C); // V10 Contract Address
        oldV12Contract = IAutoPoolFundV12(0x7eacF314B0016A3DB8F29a1405922D47068cF440); // Set this for V12 to V12 migration
        users[admin].isActive = true;
        users[admin].lastJoinTime = block.timestamp;
        users[admin].joinCount = 1;
    }

    // Main Join Function
    function join(address referrer) external migrationCompleteOnly noReentrant {
        User storage user = users[msg.sender];

        // If user has reached ROI limit, they must rejoin
        if (user.reachedTotalLimit) {
                    require(usdt.transferFrom(msg.sender, address(this), REJOIN_FEE), "Transfer failed");

        user.rejoinCount += 1;
        user.reachedTotalLimit = false;
        user.isActive = true;
        user.lastJoinTime = block.timestamp;
        user.lastROITime = 0;
        user.joinCount += 1;
        
        userLastROIUpdate[msg.sender] = block.timestamp;

        require(usdt.transfer(admin, ADMIN_FEE_PER_JOIN), "Admin fee failed");
            totalFundsReceived += REJOIN_FEE;

            // Re-enter autopool system
            _enterUserIntoAutopool(msg.sender);

            emit UserRejoined(msg.sender, user.referrer, REJOIN_FEE);
            return;
        }

        // First time join
        require(!user.isActive && user.joinCount == 0, "Already joined or active");
        require(usdt.transferFrom(msg.sender, address(this), ENTRY_FEE), "Fee transfer failed");

        // Determine referrer
        address actualReferrer = admin;
        if (referrer != address(0) && referrer != msg.sender && users[referrer].isActive) {
            actualReferrer = referrer;
        }
        user.referrer = actualReferrer;
        addToDownlines(actualReferrer, msg.sender);
        users[actualReferrer].directReferrals += 1;

        // Initialize user
        user.isActive = true;
        user.lastJoinTime = block.timestamp;
        user.joinCount = 1;
        user.rejoinCount = 0;
        user.directReferrals = 0;
        
        // Initialize ROI tracking for hourly payments
        userLastROIUpdate[msg.sender] = block.timestamp;
        userPendingROI[msg.sender] = 0;

        // Enter autopool system
        _enterUserIntoAutopool(msg.sender);

        totalUsers += 1;
        totalFundsReceived += ENTRY_FEE;

        require(usdt.transfer(admin, ADMIN_FEE_FROM_ENTRY), "Admin fee failed");
         
        emit UserJoined(msg.sender, user.referrer, ENTRY_FEE);
    }

    // Combined Profit Rejoin
    function rejoinWithCombinedProfits() external migrationCompleteOnly noReentrant {
        User storage user = users[msg.sender];
        require(user.reachedTotalLimit, "Not ready to rejoin");
        
        _updatePendingROI(msg.sender);
        
        uint256 pendingROI = userPendingROI[msg.sender];
        uint256 autopoolEarnings = autopoolPendingBalance[msg.sender];
        uint256 totalCombined = pendingROI + autopoolEarnings;
        
        require(totalCombined >= COMBINED_PROFIT_THRESHOLD, "Need 20 USDT combined");

        // Calculate proportional deduction (10 USDT total)
        uint256 roiDeduction = (REJOIN_FEE * pendingROI) / totalCombined;
        uint256 autopoolDeduction = REJOIN_FEE - roiDeduction;
        
        // Deduct from both balances
        userPendingROI[msg.sender] -= roiDeduction;
        autopoolPendingBalance[msg.sender] -= autopoolDeduction;
        
        // Update combined profits tracking
        userCombinedProfits[msg.sender] = userPendingROI[msg.sender] + autopoolPendingBalance[msg.sender];

        user.rejoinCount += 1;
        user.reachedTotalLimit = false;
        user.isActive = true;
        user.lastJoinTime = block.timestamp;
        user.lastROITime = 0;
        user.joinCount += 1;
        
        // Reset ROI update time for new cycle
        userLastROIUpdate[msg.sender] = block.timestamp;

        // Admin gets fee (already covered by deducted amounts)
        require(usdt.transfer(admin, ADMIN_FEE_PER_JOIN), "Admin fee failed");
        totalFundsReceived += REJOIN_FEE;
        totalCombinedProfitRejoins += 1;

        // Re-enter autopool system
        _enterUserIntoAutopool(msg.sender);

        emit CombinedProfitRejoin(msg.sender, roiDeduction, autopoolDeduction, block.timestamp);
        emit UserRejoined(msg.sender, user.referrer, REJOIN_FEE);
    }

    // ROI System
    
    function _updatePendingROI(address userAddr) internal {
        User storage user = users[userAddr];
        
        // Only accumulate if user is active and hasn't reached limit
        if (!user.isActive || user.reachedTotalLimit) {
            return;
        }
        
        // Check if user has already reached profit cap
        uint256 currentCombined = userPendingROI[userAddr] + autopoolPendingBalance[userAddr];
        if (currentCombined >= MAX_PROFIT_CAP) {
            return; // Stop accumulating ROI if already at or above 20 USDT cap
        }
        
        // Check direct referral requirements
        uint256 totalDirects = getTotalDirectReferrals(userAddr);
        uint256 activeDirects = getActiveDirectReferrals(userAddr);
        
        if (totalDirects < MIN_TOTAL_DIRECT_REFERRALS || activeDirects < MIN_ACTIVE_DIRECT_REFERRALS) {
            return; // Don't accumulate if requirements not met
        }
        
        // Check upline chain
        (bool isChainActive,) = isUplineChainActive(userAddr);
        if (!isChainActive) {
            return; // Don't accumulate if upline chain broken
        }
        
        uint256 lastUpdate = userLastROIUpdate[userAddr];
        if (lastUpdate == 0) {
            lastUpdate = user.lastJoinTime;
        }
        
        uint256 hoursPassed = (block.timestamp - lastUpdate) / ROI_INTERVAL;
        
        if (hoursPassed > 0) {
            uint256 roiToAdd = hoursPassed * HOURLY_ROI_AMOUNT;
            
            // Apply profit cap: ensure combined profits don't exceed 20 USDT
            uint256 newCombined = currentCombined + roiToAdd;
            if (newCombined > MAX_PROFIT_CAP) {
                roiToAdd = MAX_PROFIT_CAP - currentCombined; // Only add up to the cap
            }
            
            if (roiToAdd > 0) {
                userPendingROI[userAddr] += roiToAdd;
                userLastROIUpdate[userAddr] = lastUpdate + (hoursPassed * ROI_INTERVAL);
                
                // Update combined profits
                userCombinedProfits[userAddr] = userPendingROI[userAddr] + autopoolPendingBalance[userAddr];
                
                emit HourlyROIAccumulated(userAddr, roiToAdd, userPendingROI[userAddr], block.timestamp);
                
                // Check if combined profits threshold reached
                bool thresholdReached = userCombinedProfits[userAddr] >= COMBINED_PROFIT_THRESHOLD;
                emit CombinedProfitUpdated(userAddr, userCombinedProfits[userAddr], thresholdReached);
                
                // Check if profit cap reached
                if (userCombinedProfits[userAddr] >= MAX_PROFIT_CAP) {
                    emit ProfitCapReached(userAddr, userCombinedProfits[userAddr], block.timestamp);
                }
            }
        }
    }
    
    function updatePendingROI(address userAddr) external {
        _updatePendingROI(userAddr);
    }
    function claimROI() external migrationCompleteOnly noReentrant {
        require(usdt.balanceOf(address(this)) >= MIN_CONTRACT_BALANCE, "Low balance");
        
        uint256 totalDirects = getTotalDirectReferrals(msg.sender);
        uint256 activeDirects = getActiveDirectReferrals(msg.sender);
        require(totalDirects >= MIN_TOTAL_DIRECT_REFERRALS, "Need 2 direct refs");
        require(activeDirects >= MIN_ACTIVE_DIRECT_REFERRALS, "Need 1 active ref");
        
        _updatePendingROI(msg.sender);
        
        uint256 pending = userPendingROI[msg.sender];
        require(pending >= MIN_CLAIM_AMOUNT, "Min 20 USDT");
        require(usdt.balanceOf(address(this)) >= pending, "Insufficient balance");
        
        userPendingROI[msg.sender] = 0;
        userCombinedProfits[msg.sender] = autopoolPendingBalance[msg.sender];
        
        if (pending >= MIN_CLAIM_AMOUNT) {
            users[msg.sender].isActive = false;
            users[msg.sender].reachedTotalLimit = true;
        }
        
        require(usdt.transfer(msg.sender, pending), "Transfer failed");
        totalPaidOut += pending;
        
        emit ROIClaimed(msg.sender, pending);
    }

    // Autopool System
    
    function _enterUserIntoAutopool(address userAddr) internal {
        address teamLeader = _getTeamLeader(userAddr);
        userTeamLeader[userAddr] = teamLeader;
        
        teamAutopoolQueue[teamLeader].push(userAddr);
        autopoolPosition[userAddr] = teamAutopoolQueue[teamLeader].length - 1;
        isAutopoolActive[userAddr] = true;
        
        processTeamAutopool(teamLeader);
    }

    function _getTeamLeader(address userAddr) internal view returns (address) {
        address referrer = users[userAddr].referrer;
        if (referrer != address(0) && referrer != userAddr && users[referrer].isActive) {
            return referrer;
        }
        return admin;
    }

    function processTeamAutopool(address teamLeader) internal {
        address[] storage queue = teamAutopoolQueue[teamLeader];
        
        if (queue.length >= TEAM_POOL_SIZE) {
            address payoutUser = queue[0];
            
            if (payoutUser != address(0)) {
                // Check profit cap before adding autopool earnings
                uint256 currentCombined = userPendingROI[payoutUser] + autopoolPendingBalance[payoutUser];
                
                if (currentCombined < MAX_PROFIT_CAP) {
                    uint256 autopoolToAdd = AUTOPOOL_COMMISSION;
                    
                    // Apply profit cap for autopool earnings too
                    if (currentCombined + autopoolToAdd > MAX_PROFIT_CAP) {
                        autopoolToAdd = MAX_PROFIT_CAP - currentCombined;
                    }
                    
                    if (autopoolToAdd > 0) {
                        autopoolPendingBalance[payoutUser] += autopoolToAdd;
                        autopoolTotalEarned[payoutUser] += autopoolToAdd;
                        
                        // Update combined profits
                        userCombinedProfits[payoutUser] = userPendingROI[payoutUser] + autopoolPendingBalance[payoutUser];
                        
                        emit AutopoolPayout(payoutUser, teamLeader, autopoolToAdd, 0);
                        
                        // Check if combined profits threshold reached
                        bool thresholdReached = userCombinedProfits[payoutUser] >= COMBINED_PROFIT_THRESHOLD;
                        emit CombinedProfitUpdated(payoutUser, userCombinedProfits[payoutUser], thresholdReached);
                        
                        // Check if profit cap reached
                        if (userCombinedProfits[payoutUser] >= MAX_PROFIT_CAP) {
                            emit ProfitCapReached(payoutUser, userCombinedProfits[payoutUser], block.timestamp);
                        }
                    }
                }
                // If user already at cap, they don't get autopool payout
                
                // Rotate queue regardless of payout (to keep autopool moving)
                for (uint256 i = 0; i < queue.length - 1; i++) {
                    queue[i] = queue[i + 1];
                    autopoolPosition[queue[i]] = i;
                }
                queue[queue.length - 1] = payoutUser;
                autopoolPosition[payoutUser] = queue.length - 1;
            }
        }
    }

    function claimAutopoolEarnings() external noReentrant {
        uint256 totalDirects = getTotalDirectReferrals(msg.sender);
        uint256 activeDirects = getActiveDirectReferrals(msg.sender);
        require(totalDirects >= MIN_TOTAL_DIRECT_REFERRALS, "Need 2 direct refs");
        require(activeDirects >= MIN_ACTIVE_DIRECT_REFERRALS, "Need 1 active ref");
        
        uint256 pending = autopoolPendingBalance[msg.sender];
        require(pending >= MIN_CLAIM_AMOUNT, "Min 20 USDT");
        require(usdt.balanceOf(address(this)) >= pending, "Insufficient balance");
        
        autopoolPendingBalance[msg.sender] = 0;
        
        _updatePendingROI(msg.sender);
        userCombinedProfits[msg.sender] = userPendingROI[msg.sender];
        
        if (pending >= MIN_CLAIM_AMOUNT) {
            users[msg.sender].isActive = false;
            users[msg.sender].reachedTotalLimit = true;
        }
        
        require(usdt.transfer(msg.sender, pending), "Transfer failed");
        totalPaidOut += pending;
        
        emit AutopoolClaimed(msg.sender, pending);
    }
    
    function claimCombinedEarnings() external noReentrant {
        uint256 totalDirects = getTotalDirectReferrals(msg.sender);
        uint256 activeDirects = getActiveDirectReferrals(msg.sender);
        require(totalDirects >= MIN_TOTAL_DIRECT_REFERRALS, "Need 2 direct refs");
        require(activeDirects >= MIN_ACTIVE_DIRECT_REFERRALS, "Need 1 active ref");
        
        _updatePendingROI(msg.sender);
        
        uint256 roiPending = userPendingROI[msg.sender];
        uint256 autopoolPending = autopoolPendingBalance[msg.sender];
        uint256 totalPending = roiPending + autopoolPending;
        
        require(totalPending >= MIN_CLAIM_AMOUNT, "Min 20 USDT total");
        require(usdt.balanceOf(address(this)) >= totalPending, "Insufficient balance");
        
        userPendingROI[msg.sender] = 0;
        autopoolPendingBalance[msg.sender] = 0;
        userCombinedProfits[msg.sender] = 0;
        
        users[msg.sender].isActive = false;
        users[msg.sender].reachedTotalLimit = true;
        
        require(usdt.transfer(msg.sender, totalPending), "Transfer failed");
        totalPaidOut += totalPending;
        
        emit CombinedProfitsClaimed(msg.sender, roiPending, autopoolPending, totalPending);
    }

    // ========== INTERNAL FUNCTIONS ==========
    function addToDownlines(address referrer, address user) internal {
        userDownlines[referrer].push(user);
    }

    function getTotalDirectReferrals(address userAddr) public view returns (uint256) {
        return users[userAddr].directReferrals;
    }

    function getActiveDirectReferrals(address userAddr) public view returns (uint256 activeCount) {
        activeCount = 0;
        User storage user = users[userAddr];

        for (uint256 i = 0; i < userDownlines[userAddr].length; i++) {
            address downline = userDownlines[userAddr][i];
            if (users[downline].isActive &&
                users[downline].lastJoinTime > user.lastJoinTime) {
                activeCount++;
            }
        }
    }

    function isUplineChainActive(address userAddr) public view returns (bool, address) {
        address currentUpline = users[userAddr].referrer;
        uint256 depth = 0;
        
        while (currentUpline != address(0) && depth < 10) {
            if (currentUpline == admin) {
                return (true, address(0));
            }
            
            User memory uplineUser = users[currentUpline];
            
            if (!uplineUser.isActive || uplineUser.reachedTotalLimit) {
                return (false, currentUpline);
            }
            
            currentUpline = uplineUser.referrer;
            depth++;
        }
        
        return (true, address(0));
    }

    // ========== VIEW FUNCTIONS ==========
    function getUserInfo(address userAddr) external view returns (UserProfileInfo memory) {
        User storage user = users[userAddr];
        return UserProfileInfo(
            user.referrer,
            user.totalEarned,
            user.lastJoinTime,
            user.isActive,
            user.reachedTotalLimit,
            user.rejoinCount,
            MIN_ACTIVE_DIRECT_REFERRALS,
            user.directReferrals
        );
    }

    /**
     * @dev Get combined profit information for a user
     */
    function getCombinedProfitInfo(address userAddr) external view returns (CombinedProfitInfo memory) {
        // Calculate current pending ROI
        uint256 currentPendingROI = _calculatePendingROI(userAddr);
        uint256 autopoolEarnings = autopoolPendingBalance[userAddr];
        uint256 totalCombined = currentPendingROI + autopoolEarnings;
        bool eligible = (users[userAddr].reachedTotalLimit && totalCombined >= COMBINED_PROFIT_THRESHOLD);
        
        uint256 shortfall = 0;
        if (totalCombined < COMBINED_PROFIT_THRESHOLD) {
            shortfall = COMBINED_PROFIT_THRESHOLD - totalCombined;
        }
        
        uint256 availableForClaim = 0;
        if (totalCombined >= MIN_CLAIM_AMOUNT) {
            availableForClaim = totalCombined;
        }
        
        string memory status;
        if (eligible) {
            status = "Ready to rejoin with combined profits (20 USDT)";
        } else if (users[userAddr].reachedTotalLimit) {
            status = string(abi.encodePacked("Need ", toString(shortfall / 1e18), " more USDT combined profits"));
        } else if (totalCombined >= MAX_PROFIT_CAP) {
            status = "At maximum profit cap (20 USDT) - must claim or rejoin";
        } else if (currentPendingROI >= MIN_CLAIM_AMOUNT) {
            status = string(abi.encodePacked("Can claim ", toString(currentPendingROI / 1e18), " USDT ROI"));
        } else if (autopoolEarnings >= MIN_CLAIM_AMOUNT) {
            status = string(abi.encodePacked("Can claim ", toString(autopoolEarnings / 1e18), " USDT autopool"));
        } else if (totalCombined >= MIN_CLAIM_AMOUNT) {
            status = string(abi.encodePacked("Can claim ", toString(totalCombined / 1e18), " USDT combined"));
        } else {
            uint256 hoursToMinClaim = (MIN_CLAIM_AMOUNT - currentPendingROI) / HOURLY_ROI_AMOUNT;
            status = string(abi.encodePacked("Accumulating ROI - need ", toString(hoursToMinClaim), " more hours for 20 USDT minimum"));
        }
        
        return CombinedProfitInfo(
            currentPendingROI,
            autopoolEarnings,
            totalCombined,
            COMBINED_PROFIT_THRESHOLD,
            eligible,
            shortfall,
            availableForClaim,
            status
        );
    }
    
    /**
     * @dev Calculate pending ROI without updating state (view function)
     * INCLUDES PROFIT CAP: No calculation beyond 20 USDT combined
     */
    function _calculatePendingROI(address userAddr) internal view returns (uint256) {
        User memory user = users[userAddr];
        
        if (!user.isActive || user.reachedTotalLimit) {
            return userPendingROI[userAddr]; // Return current balance without adding more
        }
        
        // Check if already at profit cap
        uint256 currentCombined = userPendingROI[userAddr] + autopoolPendingBalance[userAddr];
        if (currentCombined >= MAX_PROFIT_CAP) {
            return userPendingROI[userAddr]; // No more ROI if at cap
        }
        
        // Check requirements (same as _updatePendingROI but read-only)
        uint256 totalDirects = getTotalDirectReferrals(userAddr);
        uint256 activeDirects = getActiveDirectReferrals(userAddr);
        
        if (totalDirects < MIN_TOTAL_DIRECT_REFERRALS || activeDirects < MIN_ACTIVE_DIRECT_REFERRALS) {
            return userPendingROI[userAddr];
        }
        
        (bool isChainActive,) = isUplineChainActive(userAddr);
        if (!isChainActive) {
            return userPendingROI[userAddr];
        }
        
        uint256 lastUpdate = userLastROIUpdate[userAddr];
        if (lastUpdate == 0) {
            lastUpdate = user.lastJoinTime;
        }
        
        uint256 hoursPassed = (block.timestamp - lastUpdate) / ROI_INTERVAL;
        uint256 additionalROI = hoursPassed * HOURLY_ROI_AMOUNT;
        
        // Apply profit cap
        uint256 projectedCombined = currentCombined + additionalROI;
        if (projectedCombined > MAX_PROFIT_CAP) {
            additionalROI = MAX_PROFIT_CAP - currentCombined;
        }
        
        return userPendingROI[userAddr] + additionalROI;
    }

    /**
     * @dev Simulate combined profit rejoin breakdown
     */
    function simulateCombinedProfitRejoin(address userAddr) external view returns (
        uint256 totalCombinedProfits,
        uint256 roiDeduction,
        uint256 autopoolDeduction,
        uint256 remainingROI,
        uint256 remainingAutopool,
        bool canRejoin,
        string memory breakdown
    ) {
        uint256 pendingROI = _calculatePendingROI(userAddr);
        uint256 autopoolEarnings = autopoolPendingBalance[userAddr];
        totalCombinedProfits = pendingROI + autopoolEarnings;
        
        canRejoin = (users[userAddr].reachedTotalLimit && totalCombinedProfits >= COMBINED_PROFIT_THRESHOLD);
        
        if (canRejoin && totalCombinedProfits > 0) {
            roiDeduction = (REJOIN_FEE * pendingROI) / totalCombinedProfits;
            autopoolDeduction = REJOIN_FEE - roiDeduction;
            remainingROI = pendingROI - roiDeduction;
            remainingAutopool = autopoolEarnings - autopoolDeduction;
            
            breakdown = string(abi.encodePacked(
                "Deduct ", toString(roiDeduction / 1e18), " from ROI + ", 
                toString(autopoolDeduction / 1e18), " from autopool = 10 USDT rejoin fee"
            ));
        } else {
            breakdown = "Cannot rejoin - insufficient combined profits or not at ROI limit";
        }
    }

    /**
     * @dev Get economics breakdown for the new hourly system
     */
    function getEconomicsBreakdown() external pure returns (
        uint256 entryFee,
        uint256 rejoinFee,
        uint256 hourlyROI,
        uint256 autopoolCommission,
        uint256 combinedThreshold,
        uint256 minimumClaim,
        string memory model
    ) {
        entryFee = ENTRY_FEE;
        rejoinFee = REJOIN_FEE;
        hourlyROI = HOURLY_ROI_AMOUNT;
        autopoolCommission = AUTOPOOL_COMMISSION;
        combinedThreshold = COMBINED_PROFIT_THRESHOLD;
        minimumClaim = MIN_CLAIM_AMOUNT;
        
        model = "Auto-accumulate 2 USDT/hour + 5 USDT autopool - Manual claim min 20 USDT each - Max 20 USDT profit cap - Rejoin with 10 USDT when total reaches 20 USDT";
    }

    /**
     * @dev Check ROI claim eligibility and show accumulation status
     */
    function getROIClaimStatus(address userAddr) external view returns (
        bool canClaim,
        uint256 currentPendingROI,
        uint256 minimumRequired,
        uint256 hoursAccumulated,
        uint256 hoursUntilClaimable,
        string memory status
    ) {
        currentPendingROI = _calculatePendingROI(userAddr);
        minimumRequired = MIN_CLAIM_AMOUNT;
        
        User memory user = users[userAddr];
        if (user.isActive && !user.reachedTotalLimit) {
            uint256 lastUpdate = userLastROIUpdate[userAddr];
            if (lastUpdate == 0) lastUpdate = user.lastJoinTime;
            hoursAccumulated = (block.timestamp - lastUpdate) / ROI_INTERVAL;
        }
        
        if (currentPendingROI >= minimumRequired) {
            canClaim = true;
            hoursUntilClaimable = 0;
            status = string(abi.encodePacked("Ready to claim ", toString(currentPendingROI / 1e18), " USDT ROI"));
        } else {
            canClaim = false;
            uint256 shortfall = minimumRequired - currentPendingROI;
            hoursUntilClaimable = shortfall / HOURLY_ROI_AMOUNT;
            if (shortfall % HOURLY_ROI_AMOUNT > 0) hoursUntilClaimable += 1; // Round up
            
            status = string(abi.encodePacked(
                "Need ", toString(hoursUntilClaimable), " more hours to reach 20 USDT minimum (currently ", 
                toString(currentPendingROI / 1e18), " USDT)"
            ));
        }
    }

    function getDirectReferralCounts(address userAddr) external view returns (
        uint256 totalDirectReferrals,
        uint256 activeDirectReferrals
    ) {
        return (
            getTotalDirectReferrals(userAddr),
            getActiveDirectReferrals(userAddr)
        );
    }

    function getContractStats() external view returns (
        uint256 totalUsersCount,
        uint256 contractBalance,
        uint256 totalFundsReceivedAmount,
        uint256 totalPaidOutAmount,
        uint256 totalCombinedProfitRejoinsCount
    ) {
        return (
            totalUsers,
            usdt.balanceOf(address(this)),
            totalFundsReceived,
            totalPaidOut,
            totalCombinedProfitRejoins
        );
    }

    // ========== UTILITY FUNCTIONS ==========
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // ========== ADMIN FUNCTIONS ==========
    function emergencyWithdraw() external onlyAdmin {
        require(usdt.balanceOf(address(this)) > 0, "No balance to withdraw");
        require(usdt.transfer(admin, usdt.balanceOf(address(this))), "Withdraw failed");
    }

    function completeMigration() external onlyAdmin {
        migrationCompleted = true;
    }

    function getMigrationStatus() external view returns (
        bool completed,
        uint256 migratedCount
    ) {
        return (migrationCompleted, migratedUsersCount);
    }

    // ========== V10 MIGRATION FUNCTIONS ==========
    
    /**
     * @dev Migrate single user from V10 contract (refactored to avoid stack too deep)
     */
    function migrateUser(address userAddr) external onlyAdmin {
        require(!hasBeenMigrated[userAddr], "User already migrated");
        require(!migrationCompleted, "Migration completed");
        
        (
            address oldReferrer,
            uint256 oldTotalEarned,
            uint256 oldDirectReferrals,
            uint256 oldLastJoinTime,
            uint256 oldLastROITime,
            ,
            uint256 oldJoinCount,
            bool oldIsActive,
            bool oldReachedTotalLimit
        ) = oldAutoPoolFund.users(userAddr);
        
        // Only migrate if user existed in V10
        if (oldLastJoinTime > 0) {
            _setUserBasicData(userAddr, oldReferrer, oldTotalEarned, oldLastJoinTime, oldLastROITime, oldJoinCount, oldIsActive, oldReachedTotalLimit, oldDirectReferrals);
            _setUserEarningsData(userAddr);
            _migrateUserDownlines(userAddr);
            
            // Enter into autopool if active
            if (oldIsActive && !oldReachedTotalLimit) {
                _enterUserIntoAutopool(userAddr);
            }
            
            _finalizeUserMigration(userAddr);
        }
    }
    
    /**
     * @dev Batch migrate users from V10
     */
    function migrateUsersBatch(address[] calldata userAddrs) external onlyAdmin {
        require(!migrationCompleted, "Migration completed");
        
        for (uint256 i = 0; i < userAddrs.length; i++) {
            address userAddr = userAddrs[i];
            if (hasBeenMigrated[userAddr]) continue;
            
            _migrateSingleUserFromV10(userAddr);
        }
    }
    
    /**
     * @dev Internal function to migrate a single user (reduces stack depth)
     */
    function _migrateSingleUserFromV10(address userAddr) internal {
        (
            address oldReferrer,
            uint256 oldTotalEarned,
            uint256 oldDirectReferrals,
            uint256 oldLastJoinTime,
            uint256 oldLastROITime,
            ,
            uint256 oldJoinCount,
            bool oldIsActive,
            bool oldReachedTotalLimit
        ) = oldAutoPoolFund.users(userAddr);
        
        if (oldLastJoinTime > 0) {
            _setUserBasicData(userAddr, oldReferrer, oldTotalEarned, oldLastJoinTime, oldLastROITime, oldJoinCount, oldIsActive, oldReachedTotalLimit, oldDirectReferrals);
            _setUserEarningsData(userAddr);
            _migrateUserDownlines(userAddr);
            
            if (oldIsActive && !oldReachedTotalLimit) {
                _enterUserIntoAutopool(userAddr);
            }
            
            _finalizeUserMigration(userAddr);
        }
    }
    
    /**
     * @dev Set basic user data (reduces stack depth)
     */
    function _setUserBasicData(
        address userAddr,
        address referrer,
        uint256 totalEarned,
        uint256 lastJoinTime,
        uint256 lastROITime,
        uint256 joinCount,
        bool isActive,
        bool reachedTotalLimit,
        uint256 directReferrals
    ) internal {
        User storage newUser = users[userAddr];
        newUser.referrer = referrer;
        newUser.totalEarned = totalEarned;
        newUser.lastJoinTime = lastJoinTime;
        newUser.lastROITime = lastROITime;
        newUser.joinCount = joinCount;
        newUser.isActive = isActive;
        newUser.reachedTotalLimit = reachedTotalLimit;
        newUser.rejoinCount = 0;
        newUser.directReferrals = directReferrals;
    }
    
    /**
     * @dev Set user earnings data (reduces stack depth)
     */
    function _setUserEarningsData(address userAddr) internal {
        uint256 oldROIClaims = oldAutoPoolFund.userTotalROIClaims(userAddr);
        uint256 estimatedROICycles = 0;
        if (oldROIClaims > 0) {
            estimatedROICycles = oldROIClaims / (15 * 1e18);
        }
        uint256 preservedHourlyROI = estimatedROICycles * HOURLY_ROI_AMOUNT;
        
        userPendingROI[userAddr] = preservedHourlyROI;
        userLastROIUpdate[userAddr] = block.timestamp;
        userCombinedProfits[userAddr] = preservedHourlyROI;
        userTotalROIClaims[userAddr] = oldROIClaims;
    }
    
    /**
     * @dev Migrate user downlines (reduces stack depth)
     */
    function _migrateUserDownlines(address userAddr) internal {
        uint256 downlineCount = oldAutoPoolFund.userDownlineCount(userAddr);
        for (uint256 j = 0; j < downlineCount && j < 50; j++) {
            try oldAutoPoolFund.userDownlines(userAddr, j) returns (address downline) {
                if (downline != address(0)) {
                    userDownlines[userAddr].push(downline);
                }
            } catch {
                continue;
            }
        }
    }
    
    /**
     * @dev Finalize user migration (reduces stack depth)
     */
    function _finalizeUserMigration(address userAddr) internal {
        totalUsers++;
        migratedUsersCount++;
        hasBeenMigrated[userAddr] = true;
        migratedUsers.push(userAddr);
    }
    
    /**
     * @dev Auto-discover and migrate V10 users
     */
    function migrateV10Users(uint256 batchSize) external onlyAdmin {
        require(!migrationCompleted, "Migration already completed");
        require(batchSize > 0 && batchSize <= 100, "Invalid batch size");
        
        _processMigrationBatch(batchSize);
    }
    
    /**
     * @dev Internal function to process migration in batches
     */
    function _processMigrationBatch(uint256 batchSize) internal {
        uint256 processed = 0;
        
        if (totalUsersToMigrate == 0) {
            address[] memory comprehensiveUserList = _getAllV10UsersComprehensive();
            totalUsersToMigrate = comprehensiveUserList.length;
        }
        
        address[] memory allV10Users = _getAllV10UsersComprehensive();
        
        for (uint256 i = migrationCurrentIndex; i < allV10Users.length && processed < batchSize; i++) {
            address userAddr = allV10Users[i];
            
            if (!hasBeenMigrated[userAddr] && userAddr != address(0)) {
                if (_migrateV10UserWithDownlines(userAddr)) {
                    processed++;
                }
            }
            
            migrationCurrentIndex++;
        }
        
        if (migrationCurrentIndex >= allV10Users.length) {
            migrationCompleted = true;
        }
    }
    
    /**
     * @dev Get all V10 users for comprehensive migration
     */
    function _getAllV10UsersComprehensive() internal view returns (address[] memory) {
        uint256 v10MigratedCount = oldAutoPoolFund.migratedUsersCount();
        address[] memory allReferrers;
        
        try oldAutoPoolFund.getAllReferrers() returns (address[] memory refs) {
            allReferrers = refs;
        } catch {
            allReferrers = new address[](0);
        }
        
        uint256 v10Total = oldAutoPoolFund.totalUsers();
        uint256 maxPossibleUsers = v10Total + 1000;
        address[] memory tempUsers = new address[](maxPossibleUsers);
        uint256 userCount = 0;
        
        // Add migrated users from V10
        for (uint256 i = 0; i < v10MigratedCount; i++) {
            try oldAutoPoolFund.migratedUsers(i) returns (address user) {
                if (user != address(0) && !_isUserInArray(tempUsers, userCount, user)) {
                    if (_isValidV10User(user)) {
                        tempUsers[userCount] = user;
                        userCount++;
                    }
                }
            } catch { continue; }
        }
        
        // Add referrers and their downlines
        for (uint256 i = 0; i < allReferrers.length; i++) {
            address referrer = allReferrers[i];
            if (referrer != address(0) && !_isUserInArray(tempUsers, userCount, referrer)) {
                if (_isValidV10User(referrer)) {
                    tempUsers[userCount] = referrer;
                    userCount++;
                }
            }
            
            try oldAutoPoolFund.userDownlineCount(referrer) returns (uint256 downlineCount) {
                for (uint256 k = 0; k < downlineCount; k++) {
                    try oldAutoPoolFund.userDownlines(referrer, k) returns (address downline) {
                        if (downline != address(0) && !_isUserInArray(tempUsers, userCount, downline)) {
                            if (_isValidV10User(downline)) {
                                tempUsers[userCount] = downline;
                                userCount++;
                            }
                        }
                    } catch { continue; }
                }
            } catch {
                try oldAutoPoolFund.teamSizes(referrer) returns (uint256 teamSize) {
                    for (uint256 j = 0; j < teamSize; j++) {
                        try oldAutoPoolFund.teamPools(referrer, j) returns (address member) {
                            if (member != address(0) && !_isUserInArray(tempUsers, userCount, member)) {
                                if (_isValidV10User(member)) {
                                    tempUsers[userCount] = member;
                                    userCount++;
                                }
                            }
                        } catch { continue; }
                    }
                } catch { continue; }
            }
        }
        
        address[] memory finalUsers = new address[](userCount);
        for (uint256 i = 0; i < userCount; i++) {
            finalUsers[i] = tempUsers[i];
        }
        return finalUsers;
    }
    
    /**
     * @dev Internal function to migrate a single V10 user with downlines
     */
    function _migrateV10UserWithDownlines(address userAddr) internal returns (bool) {
        if (hasBeenMigrated[userAddr] || userAddr == address(0)) return false;
        
        (
            address oldReferrer,
            uint256 oldTotalEarned,
            uint256 oldDirectReferrals,
            uint256 oldLastJoinTime,
            uint256 oldLastROITime,
            ,
            uint256 oldJoinCount,
            bool oldIsActive,
            bool oldReachedTotalLimit
        ) = oldAutoPoolFund.users(userAddr);
        
        if (oldLastJoinTime == 0) return false;
        
        _setUserBasicData(userAddr, oldReferrer, oldTotalEarned, oldLastJoinTime, oldLastROITime, oldJoinCount, oldIsActive, oldReachedTotalLimit, oldDirectReferrals);
        _setUserEarningsData(userAddr);
        _migrateUserDownlines(userAddr);
        
        if (oldIsActive && !oldReachedTotalLimit) {
            _enterUserIntoAutopool(userAddr);
        }
        
        _finalizeUserMigration(userAddr);
        
        return true;
    }
    
    /**
     * @dev Check if V10 user is valid
     */
    function _isValidV10User(address userAddr) internal view returns (bool) {
        try oldAutoPoolFund.users(userAddr) returns (
            address,
            uint256,
            uint256,
            uint256 lastJoinTime,
            uint256,
            uint256,
            uint256,
            bool,
            bool
        ) {
            return lastJoinTime > 0;
        } catch {
            return false;
        }
    }
    
    /**
     * @dev Check if user is already in array
     */
    function _isUserInArray(address[] memory array, uint256 length, address user) internal pure returns (bool) {
        for (uint256 i = 0; i < length; i++) {
            if (array[i] == user) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * @dev Get migration progress
     */
    function getMigrationProgress() external view returns (
        uint256 totalToMigrate,
        uint256 currentIndex,
        uint256 migratedCount,
        bool completed
    ) {
        return (
            totalUsersToMigrate,
            migrationCurrentIndex,
            migratedUsersCount,
            migrationCompleted
        );
    }
    
    /**
     * @dev Get migration status and preserved earnings for a user
     */
    function getUserMigrationInfo(address userAddr) external view returns (
        bool isMigrated,
        uint256 preservedHourlyROI,
        uint256 oldTotalROIClaims,
        uint256 estimatedOldROICycles,
        uint256 currentCombinedProfits,
        string memory migrationStatus
    ) {
        isMigrated = hasBeenMigrated[userAddr];
        preservedHourlyROI = userPendingROI[userAddr];
        oldTotalROIClaims = userTotalROIClaims[userAddr];
        currentCombinedProfits = userCombinedProfits[userAddr];
        
        if (oldTotalROIClaims > 0) {
            estimatedOldROICycles = oldTotalROIClaims / (15 * 1e18);
        }
        
        if (isMigrated) {
            if (preservedHourlyROI > 0) {
                migrationStatus = string(abi.encodePacked(
                    "Migrated with ", 
                    toString(preservedHourlyROI / 1e18), 
                    " USDT preserved ROI from ", 
                    toString(estimatedOldROICycles), 
                    " V10 cycles. Active directs reset to 0."
                ));
            } else {
                migrationStatus = "Migrated - fresh start in V11 with active directs reset to 0";
            }
        } else {
            migrationStatus = "Not yet migrated from V10";
        }
    }
    
    /**
     * @dev Force migrate specific users (admin only)
     */
    function forceMigrateUsers(address[] calldata userAddresses) external onlyAdmin {
        require(userAddresses.length <= 50, "Too many users (max 50)");
        
        for (uint256 i = 0; i < userAddresses.length; i++) {
            if (!hasBeenMigrated[userAddresses[i]] && _isValidV10User(userAddresses[i])) {
                _migrateV10UserWithDownlines(userAddresses[i]);
            }
        }
    }

    // ========== V12 TO V12 MIGRATION FUNCTIONS ==========
    
    /**
     * @dev Set old V12 contract address for V12 to V12 migration (admin only)
     */
    function setOldV12Contract(address oldV12Address) external onlyAdmin {
        require(oldV12Address != address(0), "Invalid contract address");
        oldV12Contract = IAutoPoolFundV12(oldV12Address);
    }
    
    /**
     * @dev Migrate single user from old V12 contract
     */
    function migrateV12User(address userAddr) external onlyAdmin {
        require(address(oldV12Contract) != address(0), "Old V12 contract not set");
        require(!hasBeenMigrated[userAddr], "User already migrated");
        require(!migrationCompleted, "Migration completed");
        
        // Check if user was already migrated in old contract
        try oldV12Contract.hasBeenMigrated(userAddr) returns (bool wasMigrated) {
            require(wasMigrated, "User was not migrated in old V12 contract");
        } catch {
            // If function doesn't exist, continue with migration
        }
        
        (
            address oldReferrer,
            uint256 oldTotalEarned,
            uint256 oldLastJoinTime,
            uint256 oldLastROITime,
            uint256 oldJoinCount,
            uint256 oldRejoinCount,
            bool oldIsActive,
            bool oldReachedTotalLimit,
            uint256 oldDirectReferrals
        ) = oldV12Contract.users(userAddr);
        
        // Only migrate if user existed in old V12
        if (oldLastJoinTime > 0) {
            _setV12UserBasicData(userAddr, oldReferrer, oldTotalEarned, oldLastJoinTime, oldLastROITime, 
                               oldJoinCount, oldRejoinCount, oldIsActive, oldReachedTotalLimit, oldDirectReferrals);
            _setV12UserEarningsData(userAddr);
            _migrateV12UserDownlines(userAddr);
            
            // Enter into autopool if active
            if (oldIsActive && !oldReachedTotalLimit) {
                _enterUserIntoAutopool(userAddr);
            }
            
            _finalizeUserMigration(userAddr);
        }
    }
    
    /**
     * @dev Batch migrate users from old V12 contract
     */
    function migrateV12UsersBatch(address[] calldata userAddrs) external onlyAdmin {
        require(address(oldV12Contract) != address(0), "Old V12 contract not set");
        require(!migrationCompleted, "Migration completed");
        
        for (uint256 i = 0; i < userAddrs.length; i++) {
            address userAddr = userAddrs[i];
            if (hasBeenMigrated[userAddr]) continue;
            
            _migrateV12SingleUser(userAddr);
        }
    }
    
    /**
     * @dev Internal function to migrate a single V12 user
     */
    function _migrateV12SingleUser(address userAddr) internal {
        try oldV12Contract.users(userAddr) returns (
            address oldReferrer,
            uint256 oldTotalEarned,
            uint256 oldLastJoinTime,
            uint256 oldLastROITime,
            uint256 oldJoinCount,
            uint256 oldRejoinCount,
            bool oldIsActive,
            bool oldReachedTotalLimit,
            uint256 oldDirectReferrals
        ) {
            if (oldLastJoinTime > 0) {
                _setV12UserBasicData(userAddr, oldReferrer, oldTotalEarned, oldLastJoinTime, oldLastROITime, 
                                   oldJoinCount, oldRejoinCount, oldIsActive, oldReachedTotalLimit, oldDirectReferrals);
                _setV12UserEarningsData(userAddr);
                _migrateV12UserDownlines(userAddr);
                
                if (oldIsActive && !oldReachedTotalLimit) {
                    _enterUserIntoAutopool(userAddr);
                }
                
                _finalizeUserMigration(userAddr);
            }
        } catch {
            // Skip users that can't be read
        }
    }
    
    /**
     * @dev Set V12 user basic data (preserves V12 structure)
     */
    function _setV12UserBasicData(
        address userAddr,
        address referrer,
        uint256 totalEarned,
        uint256 lastJoinTime,
        uint256 lastROITime,
        uint256 joinCount,
        uint256 rejoinCount,
        bool isActive,
        bool reachedTotalLimit,
        uint256 directReferrals
    ) internal {
        User storage newUser = users[userAddr];
        newUser.referrer = referrer;
        newUser.totalEarned = totalEarned;
        newUser.lastJoinTime = lastJoinTime;
        newUser.lastROITime = lastROITime;
        newUser.joinCount = joinCount;
        newUser.rejoinCount = rejoinCount;
        newUser.isActive = isActive;
        newUser.reachedTotalLimit = reachedTotalLimit;
        newUser.directReferrals = directReferrals;
    }
    
    /**
     * @dev Set V12 user earnings data (preserves existing balances)
     */
    function _setV12UserEarningsData(address userAddr) internal {
        try oldV12Contract.userPendingROI(userAddr) returns (uint256 oldPendingROI) {
            userPendingROI[userAddr] = oldPendingROI;
        } catch {
            userPendingROI[userAddr] = 0;
        }
        
        try oldV12Contract.autopoolPendingBalance(userAddr) returns (uint256 oldAutopoolBalance) {
            autopoolPendingBalance[userAddr] = oldAutopoolBalance;
        } catch {
            autopoolPendingBalance[userAddr] = 0;
        }
        
        try oldV12Contract.userCombinedProfits(userAddr) returns (uint256 oldCombinedProfits) {
            userCombinedProfits[userAddr] = oldCombinedProfits;
        } catch {
            userCombinedProfits[userAddr] = userPendingROI[userAddr] + autopoolPendingBalance[userAddr];
        }
        
        try oldV12Contract.userTotalROIClaims(userAddr) returns (uint256 oldROIClaims) {
            userTotalROIClaims[userAddr] = oldROIClaims;
        } catch {
            userTotalROIClaims[userAddr] = 0;
        }
        
        userLastROIUpdate[userAddr] = block.timestamp;
    }
    
    /**
     * @dev Migrate V12 user downlines
     */
    function _migrateV12UserDownlines(address userAddr) internal {
        // Try to get downlines from old contract
        for (uint256 j = 0; j < 100; j++) { // Limit to prevent gas issues
            try oldV12Contract.userDownlines(userAddr, j) returns (address downline) {
                if (downline != address(0)) {
                    userDownlines[userAddr].push(downline);
                } else {
                    break; // No more downlines
                }
            } catch {
                break; // No more downlines or function doesn't exist
            }
        }
    }
    
    /**
     * @dev Get V12 migration status
     */
    function getV12MigrationInfo() external view returns (
        address oldV12ContractAddress,
        bool isV12ContractSet,
        uint256 estimatedV12Users
    ) {
        oldV12ContractAddress = address(oldV12Contract);
        isV12ContractSet = oldV12ContractAddress != address(0);
        
        if (isV12ContractSet) {
            try oldV12Contract.totalUsers() returns (uint256 v12TotalUsers) {
                estimatedV12Users = v12TotalUsers;
            } catch {
                estimatedV12Users = 0;
            }
        } else {
            estimatedV12Users = 0;
        }
    }
}