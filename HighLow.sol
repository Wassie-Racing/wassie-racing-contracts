// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@api3/airnode-protocol/contracts/rrp/requesters/RrpRequesterV0.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

struct Pool {
    uint256 totalShares; 
    uint256 totalBalance;
}

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


interface IWassieRacing{
        function housePools(address token) external view returns (Pool memory); 
        function addHouseBalance(address token, uint256 fee, uint256 amountLessFee, address bettor) external;
        function subHouseBalance(address token, uint256 amount, address bettor) external;
        function isApprovedToken(address token) external view returns (bool isApproved);
}


contract HighLow is Ownable, RrpRequesterV0, ReentrancyGuard {

    IWassieRacing mainContract;
    IBlast blast = IBlast(0x4300000000000000000000000000000000000002);

    mapping(bytes32 => BetDetails) public betsByRequestId;
    mapping(bytes32 => bool) public expectingRequestWithIdToBeFulfilled; // qrng mapping
    
    enum BetChoice { Higher, Lower, Draw}

    struct BetDetails {
        address user;
        BetChoice choice;
        address token;
        uint256 amount;
        uint256 amountAfterFee;
    }

    address private airnode; // qrng
    address private sponsorWallet; //qrng
    bytes32 public endpointIdUint256;

    uint256 private constant REFERENCE_CARD_VALUE = 7;

    uint256 public feePct; // operational fee
    uint256 public housePct; // house edge
    uint256 public maxRisk; // divisor used to determine risk tolerance of house

    mapping(address => uint256) public minBet;
    mapping(address => bool) public hasMinBet; // mapping from token to bool for min bet

    uint256 public WinOdds=216;
    uint256 public DrawOdds=1300;
    uint256 public constant ODDSADJ = 100;
    

    event RequestedUint256(bytes32 indexed requestId);
    event ReceivedUint256(bytes32 indexed requestId, uint256 response);


    // testnet only yield/gas tracking functions
    enum ClaimType {YIELD, GAS}
    struct testYieldDetails {
        ClaimType claimType;
        uint256 claimtime;
        uint256 amount;
    }

    uint256 public iteratorYieldDetails;
    mapping(uint256 => testYieldDetails) public testingClaims;

    event BetPlaced(address indexed user, address indexed tokenSelection, uint256 _bet, BetChoice _choice, bytes32 requestId);
    event WagerWon (address indexed user, address indexed token, uint256 payout, uint256 result);
    event WagerLost (address indexed user, address indexed token, uint256 payout, uint256 result);

    constructor(address _mainContractAddress, address _airnodeRrp, address initialOwner) RrpRequesterV0(_airnodeRrp) Ownable(initialOwner) {
        mainContract = IWassieRacing(_mainContractAddress);
        blast.configure(YieldMode.CLAIMABLE, GasMode.CLAIMABLE, address(this));
        feePct = 5;
        housePct = 5;
        maxRisk = 100;
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


    function setRequestParameters(
        address _airnode,
        bytes32 _endpointIdUint256,
        address _sponsorWallet
    ) external onlyOwner {
        airnode = _airnode;
        endpointIdUint256 = _endpointIdUint256;
        sponsorWallet = _sponsorWallet;
    }

    function makeRequestUint256() internal returns (bytes32) {
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
        return requestId;
    }

    function fulfillUint256(bytes32 requestId, bytes calldata data) external onlyAirnodeRrp {
        require(expectingRequestWithIdToBeFulfilled[requestId], "Request ID not known");
        expectingRequestWithIdToBeFulfilled[requestId] = false;
        uint256 qrngUint256 = abi.decode(data, (uint256));
        
        //card value using random number
        uint256 cardValue = (qrngUint256 % 13) + 1; // ace is low 

        BetDetails memory bet = betsByRequestId[requestId];
        uint256 payout = 0;
        if (cardValue > REFERENCE_CARD_VALUE && bet.choice == BetChoice.Higher) {
            payout = (bet.amountAfterFee * WinOdds) * (100 - housePct) / 100 / ODDSADJ;
        } else if (cardValue < REFERENCE_CARD_VALUE && bet.choice == BetChoice.Lower) {
            payout = (bet.amountAfterFee * WinOdds) * (100 - housePct) / 100 / ODDSADJ;
        } else if (cardValue == REFERENCE_CARD_VALUE && bet.choice == BetChoice.Draw) {
            payout = (bet.amountAfterFee * DrawOdds) * (100 - housePct) / 100 / ODDSADJ;
        }

        if (payout > 0) {
            mainContract.subHouseBalance(bet.token, payout, bet.user);
            emit WagerWon(bet.user, bet.token, payout, cardValue);
        } else {
            emit WagerLost(bet.user, bet.token, payout, cardValue);
        }

        // Reset mapping and get gas refund
        delete betsByRequestId[requestId];

        emit ReceivedUint256(requestId, qrngUint256);
    }

    function updateFeePct(uint256 feePct_) external onlyOwner {
        if(feePct_ == 0 || feePct_ > 5) {
            revert("fee must be between 1 and 5 (inclusive)");
        }
        feePct = feePct_;
    }

    function updateHousePct(uint256 housePct_) external onlyOwner {
        if(housePct_ == 0 || housePct_ > 5) {
            revert("house edge must be between 1 and 5 (inclusive)");
        }
        housePct = housePct_;
    }

    function updateMaxRisk(uint256 _maxRisk) external onlyOwner {
        require(_maxRisk >= 50, "risk divisor should be higher; too much house vol");
        maxRisk = _maxRisk;
    }

    function updateMinbet(uint256 _minBet, address token, bool _isMinBet) external onlyOwner {
        minBet[token] = _minBet;
        hasMinBet[token] = _isMinBet;
    }

    function placeBet(address tokenSelection, uint256 _bet, BetChoice _choice) public nonReentrant {
        if (_bet == 0) {
            revert("Wager must be greater than 0");
        }

        if(hasMinBet[tokenSelection] && _bet < minBet[tokenSelection]) {
            revert("Bet is too low, must cover operational costs");
        }

        require(mainContract.isApprovedToken(tokenSelection), "token not approved");

        // Fee calcaluted at 5%
        uint256 betRake = _bet * feePct / 100;

        uint256 _wager = _bet - betRake;

        uint256 risk;
        if(_choice == BetChoice.Draw) {
            risk = _wager * DrawOdds * (100 - housePct) / 100 / ODDSADJ;
        } else {
            risk = _wager * WinOdds * (100 - housePct) / 100 / ODDSADJ;
        }

        uint256 maxBet = (mainContract.housePools(tokenSelection).totalBalance) / maxRisk;

        // Checks to see if risk tolerance is larger than Bet size post fee
        if (maxBet < risk) {
            revert("This bet makes the house exceed token risk tolerance.");
        }

        mainContract.addHouseBalance(tokenSelection, betRake, _wager, msg.sender);

        bytes32 requestId = makeRequestUint256();  // Capture the returned requestId

        betsByRequestId[requestId] = BetDetails({
            user: msg.sender,
            choice: _choice,
            token: tokenSelection,
            amount: _bet,
            amountAfterFee: _wager
        });

        emit BetPlaced(msg.sender,tokenSelection, _bet, _choice, requestId);

    }
}
