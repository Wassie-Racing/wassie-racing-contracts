// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

import "@api3/airnode-protocol/contracts/rrp/requesters/RrpRequesterV0.sol";

enum YieldMode {
    AUTOMATIC,
    VOID,
    CLAIMABLE
}

enum GasMode {
    VOID,
    CLAIMABLE 
}

interface IBlast{
    // configure
    function configureContract(address contractAddress, YieldMode _yield, GasMode gasMode, address governor) external;
    function configure(YieldMode _yield, GasMode gasMode, address governor) external;

    // base configuration options
    function configureClaimableYield() external;
    function configureClaimableYieldOnBehalf(address contractAddress) external;
    function configureAutomaticYield() external;
    function configureAutomaticYieldOnBehalf(address contractAddress) external;
    function configureVoidYield() external;
    function configureVoidYieldOnBehalf(address contractAddress) external;
    function configureClaimableGas() external;
    function configureClaimableGasOnBehalf(address contractAddress) external;
    function configureVoidGas() external;
    function configureVoidGasOnBehalf(address contractAddress) external;
    function configureGovernor(address _governor) external;
    function configureGovernorOnBehalf(address _newGovernor, address contractAddress) external;

    // claim yield
    function claimYield(address contractAddress, address recipientOfYield, uint256 amount) external returns (uint256);
    function claimAllYield(address contractAddress, address recipientOfYield) external returns (uint256);

    // claim gas
    function claimAllGas(address contractAddress, address recipientOfGas) external returns (uint256);
    function claimGasAtMinClaimRate(address contractAddress, address recipientOfGas, uint256 minClaimRateBips) external returns (uint256);
    function claimMaxGas(address contractAddress, address recipientOfGas) external returns (uint256);
    function claimGas(address contractAddress, address recipientOfGas, uint256 gasToClaim, uint256 gasSecondsToConsume) external returns (uint256);

    // read functions
    function readClaimableYield(address contractAddress) external view returns (uint256);
    function readYieldConfiguration(address contractAddress) external view returns (uint8);
    function readGasParams(address contractAddress) external view returns (uint256 etherSeconds, uint256 etherBalance, uint256 lastUpdated, GasMode);
}

interface IERC20Rebasing {
  // changes the yield mode of the caller and update the balance
  // to reflect the configuration
  function configure(YieldMode) external returns (uint256);
  // "claimable" yield mode accounts can call this this claim their yield
  // to another address
  function claim(address recipient, uint256 amount) external returns (uint256);
  // read the claimable amount for an account
  function getClaimableAmount(address account) external view returns (uint256);
}


contract WassieRacing is Ownable, RrpRequesterV0 {

    uint256 public raceId;
    uint256 public timeSettled;
    uint256 public gameStarted;
    uint256 public settledPeriod;
    uint256 public bettingPeriod;
    uint256 private horseAOdds;
    uint256 private horseBOdds;
    uint256 private horseCOdds;
    uint256 private horseDOdds;
    uint256 private sumHorseOdds; 
    uint256 private betId;
    uint256 private DECIMAL_ADJUSTMENT = 10**18;

    uint8 private _riskSizingFactor = 20; // used as divisor to calculate max risk house will take per game --- eg 25 is equal to 4% risk per event
    uint8 private zachPercent;
    uint8 private smolPercent;
    uint8 private housePercent;

    bytes32 public endpointIdUint256;

    mapping(uint256 => uint256) public rawVrfList; // 
    mapping(address => mapping(address => uint256)) public userHouseShares;  // user -> token -> shares --- house balances for users in
    mapping(address => Pool) public housePools; // token -> Pool --- house pool by token
    mapping(address => mapping(bytes32 => uint256)) public userBettingPoolShares; // user address => key of pool => number of virtual shares held for game betting pool    
    mapping(bytes32 => Pool) public bettingPools; // key of pool => pool information
    mapping(uint256 => Bet) public betIds; // sequential betId -> bet details (raceId, wager, choice, betting currency, bettor address)
    mapping(address => uint256) public _totalBetsByToken; // update as bets are placed
    mapping(address => mapping(Option => uint256)) public _totalRiskByTokenAndOption;
    mapping(address => uint256) public _riskTolerancePerToken; // token address => max risk in tokens per round
    mapping(address => uint256) public houseTake; // tokenAddress => balance (split between zach, smolting and team)
    mapping(address => uint256[]) public playerBets; // user address => array of player bets
    mapping(uint256 => Option) public raceWinner; // raceId => winning selection
    mapping(uint256 => bool) public raceCompleted; // raceId => bool -- used as check to bypass unnecessary compute
    mapping(uint256 => uint256[]) public raceOdds; // raceId => game odds [A,B,C,D]
    mapping(bytes32 => bool) public expectingRequestWithIdToBeFulfilled; // qrng mapping
    
    mapping(address => address) public referralAddress; // maps address of user => address that referred them
    mapping(address => mapping(address => uint256)) public referralBalance; // tracks user earnings from referrals by token
    mapping(address => bool) public hasReferral;

    address[] public approvedTokens; // list of approved tokens to deposit as house and hence bet against
    mapping(address => bool) public isApprovedToken;

    address[] public approvedGames; // external game contracts
    mapping(address => bool) public isCurrentlyPlayableGame; // related mapping for modifier check

    address private zachxbt = 0x9D727911B54C455B0071A7B682FcF4Bc444B5596; // zachxbt.eth
    address private smolting = 0x9D727911B54C455B0071A7B682FcF4Bc444B5596; // no address for smolting at the moment, added zach in place for now
    address private houseAddress = 0x28704c13743E86C3149b1EE705CC88755ef7a0A2;
    address private airnode; // qrng
    address private sponsorWallet; //qrng
    address public rerouteContract;
    bool private smolAddressAdded = false;

    State public currentState;

    struct Pool {
        uint256 totalShares; 
        uint256 totalBalance;
    }

    struct Bet {
        uint256 raceId;
        uint256 wager;
        Option choice;
        address token;
        address bettor;
    }

    // Enum to represent the four options
    enum Option { A, B, C, D }
    enum State {
        OPEN, 		// Bets allowed
        BETTING_CLOSED,	// No more bets, waiting for randomness 
        SETTLED  	// Bets settled, payouts done 
    }

    modifier bettingSettledState() {
        require(currentState == State.SETTLED);
        _;
    }

    modifier bettingOpenState() {
        require(currentState == State.OPEN);
        _;
    }

    modifier onlyApprovedGames() {
        require(isCurrentlyPlayableGame[msg.sender], "Caller is not an approved game");
        _;
    }

    event BetPlaced(address indexed user, uint256 betId, uint256 betAmount, address indexed tokenSelection, Option choice, uint256 indexed raceId);
    event NextGameOdds(uint256 oddsA, uint256 oddsB, uint256 oddsC, uint256 oddsD);
    event RequestedUint256(bytes32 indexed requestId); //qrng
    event ReceivedUint256(bytes32 indexed requestId, uint256 response); //qrng
    event PoolChanges(address indexed token, Option indexed winner, uint256 indexed raceId, uint256 winnings, uint256 bets);
    event HouseDeposit(address indexed user, address indexed token, uint256 amount);
    event HouseWithdraw(address indexed user, address indexed token, uint256 amount);

    IBlast blast = IBlast(0x4300000000000000000000000000000000000002);
    IERC20Rebasing wethRebasing = IERC20Rebasing(0x4200000000000000000000000000000000000023);
    IERC20Rebasing usdbRebasing = IERC20Rebasing(0x4200000000000000000000000000000000000022);

    constructor(address _airnodeRrp, address initialOwner) RrpRequesterV0(_airnodeRrp) Ownable(initialOwner)  {
        currentState = State.SETTLED;
        timeSettled = block.timestamp;
        _storeVrf(0, 123456789);
        raceId = 1;
        settledPeriod = 5 minutes;
        bettingPeriod = 5 minutes;
        zachPercent = 5;
        smolPercent = 5;

        blast.configure(YieldMode.CLAIMABLE, GasMode.CLAIMABLE, address(this));
        usdbRebasing.configure(YieldMode.CLAIMABLE); // USDB yield
        wethRebasing.configure(YieldMode.CLAIMABLE); // WETH yield


        blast.configure(YieldMode.CLAIMABLE, GasMode.CLAIMABLE, address(this));
        usdbRebasing.configure(YieldMode.CLAIMABLE); // USDB yield
        wethRebasing.configure(YieldMode.CLAIMABLE); // WETH yield

    }

    function updateSmolAddress(address _smolAddress) public onlyOwner {
        require(!smolAddressAdded);
        smolting = _smolAddress;
        smolAddressAdded = true;
    }

    function readWethClaimableYield() public view returns (uint256) {
        return wethRebasing.getClaimableAmount(address(this));
    }

    function readUsdbClaimableYield() public view returns (uint256) {
        return usdbRebasing.getClaimableAmount(address(this));
    }

    function readGasParams() public view onlyOwner returns (uint256,uint256,uint256,GasMode) {
        return blast.readGasParams(address(this));
    }

    // gas used to fund QRNG sponsor wallet (and fund other OpEx if there is a shortfall from other revenues), excess deposited to house players
    function claimMaxGas(address recipient) external onlyOwner {
	blast.claimMaxGas(address(this), recipient);
    }
    
    function claimAllGas(address recipient) external onlyOwner {
	blast.claimAllGas(address(this), recipient);
    }

    function claimGasAtMinClaimRate(address recipient, uint256 minClaimRateBips) external onlyOwner {
	blast.claimGasAtMinClaimRate(address(this), recipient, minClaimRateBips);
    }

    // USDB yield passed onto house depositors of USDB to bolster returns
    function claimAllUSDBYield() external onlyOwner {
        address USDB = 0x4200000000000000000000000000000000000022;

        uint256 claimAmount = usdbRebasing.getClaimableAmount(address(this));

	    usdbRebasing.claim(rerouteContract, claimAmount);

        IERC20(0x4200000000000000000000000000000000000022).transferFrom(rerouteContract, address(this), claimAmount);

        if(claimAmount == 0) {
            revert("No yield to claim");
        }

        _topUpHouse(USDB, claimAmount);
    }

    // WETH yield passed onto house depositors of WETH to bolster returns
    function claimAllWETHYield() external onlyOwner {
        address WETH = 0x4200000000000000000000000000000000000023;
        
        uint256 claimAmount = wethRebasing.getClaimableAmount(address(this));

	wethRebasing.claim(rerouteContract, claimAmount);

        IERC20(0x4200000000000000000000000000000000000023).transferFrom(rerouteContract, address(this), claimAmount);

        if(claimAmount == 0) {
            revert("No yield to claim");
        }

        _topUpHouse(WETH, claimAmount);
    }

    function updateRerouteContract(address rerouteContract_) public onlyOwner {
        rerouteContract = rerouteContract_;
    }

    // function used to supplement the house with additional revenues generated by native yield
    function _topUpHouse(address token, uint256 amount) internal {
        if(housePools[token].totalShares == 0) {
            revert("This pool does not exist");
        }
        housePools[token].totalBalance += amount;
    }

     // function used to deposit tokens to a given house pool
    function topUpHouseExternal(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        _topUpHouse(token, amount);
    }

    function updatePeriods(uint256 settledPeriod_, uint256 bettingPeriod_) public onlyOwner {
        settledPeriod = settledPeriod_;
        bettingPeriod = bettingPeriod_;
    }

    function setRequestParameters(
        address _airnode,
        bytes32 _endpointIdUint256,
        address _sponsorWallet
    ) external onlyOwner {
        airnode = _airnode;
        endpointIdUint256 = _endpointIdUint256;
        sponsorWallet = _sponsorWallet;
    }

    function intialiseUserPool(bytes32 key) internal {
        if(bettingPools[key].totalShares == 0) {
            bettingPools[key].totalBalance += 1;
            bettingPools[key].totalShares += 1;
        }
    }

    function increaseUserVirtualShares(
        bytes32 key, 
        address user,  
        uint256 totalBalanceAdded
        ) internal {

        Pool storage pool = bettingPools[key];

        if(pool.totalShares == 0 || pool.totalBalance == 0) {
            intialiseUserPool(key);
        }
        
        uint256 vSharesAdded = (totalBalanceAdded * 
            pool.totalShares) / pool.totalBalance;
        
        userBettingPoolShares[user][key] += vSharesAdded;     

        pool.totalShares += vSharesAdded; 
        pool.totalBalance += totalBalanceAdded;

    }

    function decreaseUserVirtualShares(
        bytes32 key,
        address user,
        uint256 totalBalanceRemoved  
    ) internal {

        Pool storage pool = bettingPools[key];
        
        uint256 vSharesRemoved = (totalBalanceRemoved * 
            (pool.totalShares-1)) / (pool.totalBalance-1);
        

        userBettingPoolShares[user][key] -= vSharesRemoved;

        
        // Update pool shares - if last withdraw from pool, balances set back to zero to
        if (vSharesRemoved == pool.totalShares-1) {
            pool.totalShares = 0;
            pool.totalBalance = 0;
        } else {
            pool.totalShares -= vSharesRemoved;
            pool.totalBalance -= totalBalanceRemoved;
        }       
    }

    function getKey(
        uint256 gameId, 
        Option option, 
        address token
    ) public pure returns (bytes32) {

        return keccak256(abi.encodePacked(
            gameId,
            option,
            token
        )); 
    }

    function makeRequestUint256() internal  {
        bytes32 requestId = airnodeRrp.makeFullRequest(
            airnode,
            endpointIdUint256,
            address(this),
            sponsorWallet,
            address(this),
            this.fulfillUint256.selector,
            ""
        );
        expectingRequestWithIdToBeFulfilled[requestId] = true;
        emit RequestedUint256(requestId);
    }

    function fulfillUint256(bytes32 requestId, bytes calldata data) external onlyAirnodeRrp {
        require(expectingRequestWithIdToBeFulfilled[requestId], "Request ID not known");
        expectingRequestWithIdToBeFulfilled[requestId] = false;
        uint256 qrngUint256 = abi.decode(data, (uint256));

        _storeVrf(raceId, qrngUint256);

        currentState = State.SETTLED;

        timeSettled = block.timestamp;

        updatePoolBalances();
        resetAccountingForNewRound();
        raceId++;

        emit ReceivedUint256(requestId, qrngUint256);
    }

    // as this function is used only by the rng provider, the unnecessary mappings are deleted for the gas refund to reduce cost
    function updatePoolBalances() internal {

        Option winner = getWinningChoice(raceId);
        uint256 winningOdds = getOddsChoice(winner, raceId);

        bytes32 key;

        bytes32 aKey;
        bytes32 bKey;
        bytes32 cKey;
        bytes32 dKey;

        Option A = Option.A;
        Option B = Option.B;
        Option C = Option.C;
        Option D = Option.D;

        uint256 winnings;
        
        for (uint i = 0; i < approvedTokens.length; i++) {
            address token = approvedTokens[i];
            if(_totalBetsByToken[token] != 0) {
                winnings = 0;
                key = getKey(raceId, winner, token);

                aKey = getKey(raceId, A, token);
                bKey = getKey(raceId, B, token);
                cKey = getKey(raceId, C, token);
                dKey = getKey(raceId, D, token);

                // add all balancces from betting pools to house balance
                // then add winnings to the winning pool
                if(_totalRiskByTokenAndOption[token][A] != 0) {
                    housePools[token].totalBalance += bettingPools[aKey].totalBalance - 1;
                }
                if(_totalRiskByTokenAndOption[token][B] != 0) {
                    housePools[token].totalBalance += bettingPools[bKey].totalBalance - 1;
                }
                if(_totalRiskByTokenAndOption[token][C] != 0) {
                    housePools[token].totalBalance += bettingPools[cKey].totalBalance - 1;
                }
                if(_totalRiskByTokenAndOption[token][D] != 0) {
                    housePools[token].totalBalance += bettingPools[dKey].totalBalance - 1;
                }

                if(_totalRiskByTokenAndOption[token][winner] != 0) {
                    // divide total winnings by odds decimal adjustment
                    winnings = (winningOdds * (bettingPools[key].totalBalance - 1)) / DECIMAL_ADJUSTMENT;

                    // add winnings to the pool of the winning pool and subtract from house
                    bettingPools[key].totalBalance = winnings + 1; // one added to account for initial state of pool
                    housePools[token].totalBalance -= winnings;
                }

                if (aKey == key) {
                    delete bettingPools[bKey];
                    delete bettingPools[cKey];
                    delete bettingPools[dKey];
                }
                if (bKey == key) {
                    delete bettingPools[aKey];
                    delete bettingPools[cKey];
                    delete bettingPools[dKey];
                }
                if (cKey == key) {
                    delete bettingPools[aKey];
                    delete bettingPools[bKey];
                    delete bettingPools[dKey];
                }
                if (dKey == key) {
                    delete bettingPools[aKey];
                    delete bettingPools[bKey];
                    delete bettingPools[cKey];
                }
                emit PoolChanges(token, winner, raceId, winnings, _totalBetsByToken[token]);
            }
        } 
    }

    function setRevenueSplit(uint8 zachPct, uint8 smolPct, uint8 housePct) external onlyOwner {
        require(zachPct+smolPct+housePct == 100, "Percentages must sum to 100");
        require(zachPct >= 5 && smolPct >= 5, "Insufficient wassie budget");
        (zachPercent, smolPercent, housePercent) = (zachPct, smolPct, housePct);
    }

    // houseCut is used for paying team and operational costs, increasing token liquidity (and/or burns), DGEN holder incentives
    function allocateProfit(address _token) external onlyOwner {
        uint256 _profitToAllocate = houseTake[_token];
        if (_profitToAllocate == 0) {
            revert("No profit to distribute");
        }

        uint256 zachCut = _profitToAllocate * zachPercent / 100;
        uint256 smolCut = _profitToAllocate * smolPercent / 100;
        uint256 houseCut = _profitToAllocate - zachCut - smolCut;

        houseTake[_token] -= _profitToAllocate;

        IERC20 token = IERC20(_token);      

        token.transfer(zachxbt, zachCut);
        token.transfer(smolting, smolCut);
        token.transfer(houseAddress, houseCut);
    }

    // use to stop more bets, and only finish existing games
    function pauseGames() external onlyOwner {
        currentState = State.SETTLED;
    // set timesettled to future value to prevent new games from starting while contract is paused (to allow withdrawals from betting and house pools)
        timeSettled = block.timestamp + 52 weeks;
    }
    // restart and enable bets again
    function startGames() external onlyOwner {
    // games are restartable from the moment this function is called
        timeSettled = block.timestamp - settledPeriod;
    }

    // reset variables to allow new game and set game metadata
    function _startNewGame() internal bettingSettledState {

        _setOdds(raceId);

        _calculateMaxRisk();
        currentState = State.OPEN;

        gameStarted = block.timestamp;
    }

    function changeRiskFactor(uint8 _riskFactor) public onlyOwner {
        _riskSizingFactor = _riskFactor;
    }

    function _calculateMaxRisk() internal {
        address token; 
        uint256 balance;
        
        for (uint i = 0; i < approvedTokens.length; i++) {
            token = approvedTokens[i];

            balance = housePools[token].totalBalance;
            _riskTolerancePerToken[token] = balance / _riskSizingFactor;
        }
    }

    function getWinningChoice(uint256 raceId_) internal returns (Option) {
        if (!raceCompleted[raceId_]) {
            Option winningChoice = _processGame(raceId_);
            raceWinner[raceId_] = winningChoice;
            raceCompleted[raceId_] = true;

            return winningChoice;
        }
        return raceWinner[raceId_];
    }

    function _updateTokenBets(address token_, uint256 newBet) internal {
        _totalBetsByToken[token_] += newBet;
    }

    function updateRiskByTokenAndOption(address _token, Option _choice, uint256 wager) internal {
        uint256 choiceOdds = getOddsChoice(_choice, raceId);
        uint256 betRiskToHouse = (wager * choiceOdds) / DECIMAL_ADJUSTMENT;
        _totalRiskByTokenAndOption[_token][_choice] += betRiskToHouse;
    }

    function resetAccountingForNewRound() internal {

        for (uint i = 0; i < approvedTokens.length; i++) {
            address token = approvedTokens[i];

            delete _totalRiskByTokenAndOption[token][Option.A];
            delete _totalRiskByTokenAndOption[token][Option.B];
            delete _totalRiskByTokenAndOption[token][Option.C];
            delete _totalRiskByTokenAndOption[token][Option.D];
            
            delete _totalBetsByToken[token];
        }
    }

    // check if bet takes the house beyond risk tolerance for single event
    // adjusted for decimals of odds
    function _betWithinRisk(address _tokenChoice, Option _choice, uint256 betAmount) public view returns (bool) {
        
        uint256 _optionOdds = getOddsChoice(_choice, raceId);

        uint256 betRisk = (betAmount * _optionOdds) / DECIMAL_ADJUSTMENT;

        uint256 highestRisk = getMaxRiskForToken(_tokenChoice, betRisk, _choice);

        if (highestRisk > _totalBetsByToken[_tokenChoice] + betAmount + _riskTolerancePerToken[_tokenChoice]) {
            return false;
        } else {
            return true;
        }
    }

    // compute the maximum risk for a token considering a new bet for a specific option
    function getMaxRiskForToken(address _tokenChoice, uint256 betRisk, Option _choice) public view returns (uint256) {
        uint256 riskA = (_choice == Option.A) ? _totalRiskByTokenAndOption[_tokenChoice][Option.A] + betRisk : _totalRiskByTokenAndOption[_tokenChoice][Option.A];
        uint256 riskB = (_choice == Option.B) ? _totalRiskByTokenAndOption[_tokenChoice][Option.B] + betRisk : _totalRiskByTokenAndOption[_tokenChoice][Option.B];
        uint256 riskC = (_choice == Option.C) ? _totalRiskByTokenAndOption[_tokenChoice][Option.C] + betRisk : _totalRiskByTokenAndOption[_tokenChoice][Option.C];
        uint256 riskD = (_choice == Option.D) ? _totalRiskByTokenAndOption[_tokenChoice][Option.D] + betRisk : _totalRiskByTokenAndOption[_tokenChoice][Option.D];

        return max(riskA, max(riskB, max(riskC, riskD))); // Nested max calls to get the maximum risk
    }

    // Utility function to get the maximum of two values
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    //Checks to see if VRF recieved is already used
    function _storeVrf(uint256 raceId_, uint256 resultVrf) internal {
        rawVrfList[raceId_] = resultVrf; // = resultVrf;

    }

    function _getVrf(uint256 raceId_) internal view returns (uint256) {
        return rawVrfList[raceId_];
    }

    // read function to verify a given raceIds odds - input is -1 of raceId as 
    // the vrf that decided the previous race also determines the odds for the next
    function _getOdds(uint256 raceId_) internal returns (uint256, uint256, uint256, uint256) {
        uint256 _vrfRaw = _getVrf(raceId_-1);

        horseAOdds = (_vrfRaw % 97) + 10; // A statistically is the most likely to win on aggregate
        horseBOdds = (_vrfRaw % 67) + 10;
        horseCOdds = (_vrfRaw % 47) + 10;  // +10 to give minimum odds for each
        horseDOdds = (_vrfRaw % 17) + 10; // D is least likely, the long shot

        sumHorseOdds = horseAOdds+horseBOdds+horseCOdds+horseDOdds;

        // convert to decimal odds and adjust for house edge (97% of true probability)
        // adjust with decimal adjustment

        uint256 adjOddsA = DECIMAL_ADJUSTMENT * sumHorseOdds * 95 / 100 / horseAOdds; 

        uint256 adjOddsB = DECIMAL_ADJUSTMENT * sumHorseOdds * 95 / 100 / horseBOdds;

        uint256 adjOddsC = DECIMAL_ADJUSTMENT * sumHorseOdds * 95 / 100 / horseCOdds;

        uint256 adjOddsD = DECIMAL_ADJUSTMENT * sumHorseOdds * 95 / 100 / horseDOdds;

        return (adjOddsA, adjOddsB, adjOddsC, adjOddsD);
    }

    // return the odds for a given choice for a given raceId
    function getOddsChoice(Option horse, uint256 raceId_) public view returns (uint256) {
        uint256 _a = raceOdds[raceId_][0];
        uint256 _b = raceOdds[raceId_][1];
        uint256 _c = raceOdds[raceId_][2];
        uint256 _d = raceOdds[raceId_][3];

        if(horse == Option.A) { return _a; }
        else if(horse == Option.B) { return _b; }
        else if(horse == Option.C) { return _c; }
        else { 
            require(horse == Option.D,"Enter a valid option");
            return _d; 
        }
    }

    // make sure this is only called after balances have been updated as the odds will change the output
    function _setOdds(uint256 raceId_) internal {
        (uint256 _a, uint256 _b, uint256 _c, uint256 _d) = _getOdds(raceId_);

        raceOdds[raceId_] = [_a,_b,_c,_d];

        emit NextGameOdds(_a,_b,_c,_d);
    }

    function _processGame(uint256 raceId_) internal view returns (Option) {
        uint256 _vrf = _getVrf(raceId_); // some function for calling oracle
        uint256 _denominator = sumHorseOdds;
        uint256 _remainder = _vrf % _denominator;
        uint256 horseAMax = horseAOdds-1;
        uint256 horseBMax = horseAMax + horseBOdds;
        uint256 horseCMax = horseBMax + horseCOdds;
        // uint256 horseDMax = horseCMax + horseDOdds;
        Option _winner;
        
        if(_remainder <= horseAMax) {
            _winner = Option.A;
        }
        else if(_remainder <= horseBMax) {
            _winner = Option.B;
        }
        else if(_remainder <= horseCMax) {
            _winner = Option.C;
        }
        else {
            _winner = Option.D;
        }
        return _winner;
    }

    function houseDeposit(address token, uint256 amount) external bettingSettledState {

        Pool storage pool = housePools[token];

        if(pool.totalShares == 0) {
            revert("This pool does not exist");
        }
        
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        uint256 rake = amount / 20;

        houseTake[token] += rake;

        uint256 shares = (amount - rake) * pool.totalShares / pool.totalBalance;
        
        userHouseShares[msg.sender][token] += shares;

        pool.totalShares += shares;
        pool.totalBalance += (amount - rake);

        emit HouseDeposit(msg.sender, token, amount); 
    }

    function houseWithdraw(address token, uint256 amount) external bettingSettledState {

        Pool storage pool = housePools[token];

        uint256 rake = amount / 20;

        houseTake[token] += rake;

        uint256 shares = amount * (pool.totalShares-1) / (pool.totalBalance-1);

        userHouseShares[msg.sender][token] -= shares;

        pool.totalShares -= shares;
        pool.totalBalance -= amount;

        // Transfer tokens
        IERC20(token).transfer(msg.sender, (amount-rake));
        
        emit HouseWithdraw(msg.sender, token, amount);
    }

    function createPool(address _token) external onlyOwner {
        // check to prevent overwritting existing pool
        if (housePools[_token].totalBalance != 0 || housePools[_token].totalShares != 0) {
            revert("Duplicate pool");  
        }
        isApprovedToken[_token] = true;
        approvedTokens.push(_token);
        housePools[_token] = Pool(1, 1);
    }

    function updateReferral(address referral) external {
        if (msg.sender == referral || hasReferral[msg.sender]) {
            revert("Cannot refer yourself or change referral address");
        }
        referralAddress[msg.sender] = referral;
        hasReferral[msg.sender] = true;
    }

    function claimReferrals(address _token) external {
        uint256 balanceToClaim = referralBalance[_token][msg.sender];
        referralBalance[_token][msg.sender] = 0;
        IERC20(_token).transfer(msg.sender, balanceToClaim);
    }

    function placeBet(address _tokenSelection, uint256 _bet, Option _choice) public {
            if (_bet == 0) {
                revert("Wager must be greater than 0");
            }

            if (currentState == State.SETTLED && block.timestamp > (timeSettled + settledPeriod)) {
                _startNewGame();
            }

            //New Code
            uint256 betRake = _bet / 20;
            uint256 _wager = _bet - betRake;

            if (hasReferral[msg.sender]) {
                address referralAddress_ = referralAddress[msg.sender];
                uint256 referralAmt = _bet/100;
                referralBalance[_tokenSelection][referralAddress_] += referralAmt;
                betRake -= referralAmt;
            }

            if (!_betWithinRisk(_tokenSelection, _choice, _wager)) {
                revert("This bet makes the house exceed token risk tolerance. Choose a different option or bet less.");
            }

            if (currentState == State.OPEN) {

                IERC20(_tokenSelection).transferFrom(msg.sender, address(this), _bet);

                bytes32 key = getKey(raceId, _choice, _tokenSelection);

                increaseUserVirtualShares(key, msg.sender, _wager);

                _updateTokenBets(_tokenSelection, _wager);
                updateRiskByTokenAndOption(_tokenSelection, _choice, _wager);

                //New code
                houseTake[_tokenSelection] += betRake;

                betIds[betId] = Bet({
                    raceId: raceId,
                    wager: _bet,
                    choice: _choice,
                    token: _tokenSelection,
                    bettor: msg.sender
                });
                
                playerBets[msg.sender].push(betId);

                // add event emission for each bet
                emit BetPlaced(msg.sender, betId, _bet, _tokenSelection, _choice, raceId);

                betId++;

                if(block.timestamp > (gameStarted + bettingPeriod)) {
                    requestFinish();
                }
            }            
        }

    function claimWinningBet(uint256 gameId, address token, Option option) external {
        if(raceId > gameId || timeSettled > block.timestamp + 1 days) {
            bytes32 key = getKey(gameId, option, token);
            uint256 vSharesUser = userBettingPoolShares[msg.sender][key];

            Pool memory totalPoolShares = bettingPools[key];

            uint256 userShare = (vSharesUser * (totalPoolShares.totalBalance-1)) / (totalPoolShares.totalShares-1);
            
            uint256 totalBalanceRemoved = userShare;

            if (totalBalanceRemoved != 0) {
                decreaseUserVirtualShares(key, msg.sender, totalBalanceRemoved);
                IERC20(token).transfer(msg.sender, totalBalanceRemoved);
            } else {
                revert("User has no betting shares in this pool");
            }
        } else {
            revert("Cannot claim bet until round is concluded");
        }
    }

    function updateHouseAddress(address houseAddress_) external onlyOwner {
        houseAddress = houseAddress_;
    }

    function requestFinish() public bettingOpenState {
        if (block.timestamp > (gameStarted + bettingPeriod)) {
            currentState = State.BETTING_CLOSED;
            makeRequestUint256();
        } else {
	        revert("Please wait at least five minutes after first bet this round");
        }
    }

    function addHouseBalance(address token, uint256 fee, uint256 amountLessFee, address bettor) external onlyApprovedGames  {
        uint256 amount = fee + amountLessFee;
        IERC20(token).transferFrom(bettor, address(this), amount);
        housePools[token].totalBalance += amountLessFee;
        houseTake[token] += fee;
    }

    function subHouseBalance(address token, uint256 amount, address bettor) external onlyApprovedGames  {
        housePools[token].totalBalance -= amount;
        IERC20(token).transfer(bettor, amount);
    }

    function addApprovedGames(address gameContract) external onlyOwner {
        approvedGames.push(gameContract);
        isCurrentlyPlayableGame[gameContract] = true;
    }

    function changePlayableStatus(address gameContract, bool isApproved) external onlyOwner {
        isCurrentlyPlayableGame[gameContract] = isApproved;
    }
}
