// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
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

struct Pool {
    uint256 totalShares; 
    uint256 totalBalance;
}

interface IWassieRacing{
        function housePools(address token) external view returns (Pool memory); 
        function addHouseBalance(address token, uint256 fee, uint256 amountLessFee, address bettor) external;
        function subHouseBalance(address token, uint256 amount, address bettor) external;
        function isApprovedToken(address token) external view returns (bool isApproved);
}

contract Flip is Ownable, RrpRequesterV0, ReentrancyGuard {
    address private airnode; // qrng
    address private sponsorWallet; //qrng
    bytes32 public endpointIdUint256;

    uint256 public feePct; // operational fee
    uint256 public housePct; // house edge
    uint256 public maxRisk; // divisor used to determine risk tolerance of house

    mapping(address => uint256) public minBet;
    mapping(address => bool) public hasMinBet; // mapping from token to bool for min bet

    IWassieRacing mainContract;
    IBlast blast = IBlast(0x4300000000000000000000000000000000000002);

    mapping(bytes32 => bool) public expectingRequestWithIdToBeFulfilled; // qrng mapping

    mapping(bytes32 => FlipBet) public betDetails; // request to address mapping
    
    enum Colour {RED, YELLOW, BLUE, NULL}
    enum Pattern {PATTERN, NOPATTERN, NULL}

    struct FlipBet {
        address bettorAddress;
        address token;
        uint256 amountBeforeFee;
        uint256 amountAfterFee;
        uint8[] choices;
    }

    event RequestedUint256(bytes32 indexed requestId); //qrng
    event ReceivedUint256(bytes32 indexed requestId, uint256 response); //qrng

    event BetWon(address indexed bettor, address indexed token, uint256 amount);
    event BetLost(address indexed bettor, address indexed token, uint256 amount);

    event BetPlaced(address indexed bettor, address indexed token, bytes32 requestId, uint256 amount, Pattern pattern, Colour colour);

    constructor(address _mainContractAddress, address _airnodeRrp, address initialOwner) RrpRequesterV0(_airnodeRrp) Ownable(initialOwner)  {
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

        // settlement logic

        uint256 result = (qrngUint256 % 6) + 1;

        FlipBet memory flipBet = betDetails[requestId];

        uint8[] memory selection = flipBet.choices;

        uint256 selectionLength = selection.length;

        bool isResultInSelection = false;
        for (uint i = 0; i < selectionLength; i++) {
            if (selection[i] == result) {
                isResultInSelection = true;
                break; // Exit the loop if the result is found
            }
        }

        if(isResultInSelection) {

            uint256 betAmount = flipBet.amountAfterFee;

            uint256 rawOdds = 6 / selectionLength;

            uint256 winAmount = ((betAmount * rawOdds) * (100 - housePct)) / 100;

            mainContract.subHouseBalance(flipBet.token, winAmount, flipBet.bettorAddress);

            emit BetWon(flipBet.bettorAddress, flipBet.token, winAmount);
        } else {
            emit BetLost(flipBet.bettorAddress, flipBet.token, flipBet.amountBeforeFee);
        }

        // free up chain storage for gas refund
        delete betDetails[requestId];

        emit ReceivedUint256(requestId, qrngUint256);
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

    function betFlip(address token, uint256 amount, Colour colour, Pattern pattern) external nonReentrant {
        if(amount == 0) {
            revert("Bet must be larger than 0");
        }

        if(hasMinBet[token] && amount < minBet[token]) {
            revert("Bet is too low, must cover operational costs");
        }

        require(mainContract.isApprovedToken(token), "token not approved");

        uint256 fee = amount * feePct / 100;
        uint256 amountLessFee = amount - fee;

        mainContract.addHouseBalance(token, fee, amountLessFee, msg.sender);

        if(colour == Colour.NULL && pattern == Pattern.NULL) {
            revert("Must select one of the options");
        }

        uint8[] memory selection;

        if(pattern == Pattern.NULL) {
            if(colour == Colour.RED) {
                selection = new uint8[](2);
                selection[0] = 1;
                selection[1] = 2; 
            }
            if(colour == Colour.YELLOW) {
                selection = new uint8[](2);
                selection[0] = 3; 
                selection[1] = 4; 
            }
            if(colour == Colour.BLUE) {
                selection = new uint8[](2); 
                selection[0] = 5;
                selection[1] = 6; 
            }
        }

        if(colour == Colour.NULL) {
            if(pattern == Pattern.PATTERN) {
                selection = new uint8[](3); 
                selection[0] = 2;    
                selection[1] = 4;
                selection[2] = 6;  
            }
            if(pattern == Pattern.NOPATTERN) {
                selection = new uint8[](3); 
                selection[0] = 1;  
                selection[1] = 3;
                selection[2] = 5;  
            }            
        }

        if(pattern == Pattern.NOPATTERN && colour == Colour.RED) {
            selection = new uint8[](1);
            selection[0] = 1; 
        }

        if(pattern == Pattern.NOPATTERN && colour == Colour.YELLOW) {
            selection = new uint8[](1);
            selection[0] = 3;             
        }

        if(pattern == Pattern.NOPATTERN && colour == Colour.BLUE) {
            selection = new uint8[](1);
            selection[0] = 5;             
        }

        if(pattern == Pattern.PATTERN && colour == Colour.RED) {
            selection = new uint8[](1);
            selection[0] = 2; 
        }

        if(pattern == Pattern.PATTERN && colour == Colour.YELLOW) {
            selection = new uint8[](1);
            selection[0] = 4;             
        }

        if(pattern == Pattern.PATTERN && colour == Colour.BLUE) {
            selection = new uint8[](1);
            selection[0] = 6;             
        }

        uint256 winAmount = ((amountLessFee * (6 / selection.length)) * (100 - housePct)) / 100;

        uint256 maxBet = (mainContract.housePools(token).totalBalance)/100;

        if(winAmount > maxBet) {
            revert("Bet exceeds risk tolerance");
        }

        bytes32 requestId = makeRequestUint256();

        betDetails[requestId] = FlipBet({
            bettorAddress: msg.sender,
            token: token,
            amountBeforeFee: amount,
            amountAfterFee: amountLessFee,
            choices: selection
        });

        emit BetPlaced(msg.sender, token, requestId, amount, pattern, colour);
    }

}
