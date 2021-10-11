// SPDX-License-Identifier: MIT
import "./dependencies.sol";

pragma solidity ^0.8.0;
pragma abicoder v2;

/**
 * @title PancakePredictionV2
 */
contract Prediction is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;


    IERC20 public constant pred = IERC20(0xB2d7b35539A543bbE4c74965488fFE33c6721f0d);
    address public constant BNB = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public adminAddress; // address of the admin
    address public operatorAddress; // address of the operator

    uint256 public bufferSeconds; // number of seconds for valid execution of a prediction round
    uint256 public intervalSeconds; // interval in seconds between two prediction rounds

    uint256 public minBetAmount; // minimum betting amount (denominated in wei)
    uint256 public treasuryAmount; // treasury amount that was not claimed

    uint256 public currentEpoch; // current epoch for prediction round

    uint256 public oracleLatestRoundId; // converted from uint80 (Chainlink)
    uint256 public oracleUpdateAllowance; // seconds

    uint256 public constant MAX_TREASURY_FEE = 1000; // 10%

    mapping(uint256 => mapping(address => BetInfo)) public ledger;
    mapping(uint256 => Round) public rounds;
    mapping(address => uint256[]) public userRounds;
    mapping(address => AggregatorV3Interface) public oracles;
    
    address[] public tokens;

    enum Position {
        Bull,
        Bear
    }

    struct Round {
        uint256 epoch;
        uint256 startTimestamp;
        uint256 endTimestamp;
        uint256 totalAmount;
        bool oraclesCalled;
        mapping(address => uint256) startOracleIds;
        mapping(address => uint256) endOracleIds;
        mapping(address => int) startPrices;
        mapping(address => int) endPrices;
    }

    struct BetInfo {
        Position position;
        address token;
        uint256 amount;
        bool claimed; // default false
    }

    event BetBear(address indexed sender, uint256 indexed epoch, uint256 amount);
    event BetBull(address indexed sender, uint256 indexed epoch, uint256 amount);
    event Claim(address indexed sender, uint256 indexed epoch, uint256 amount);
    event EndRound(uint256 indexed epoch, uint256 indexed roundId, int256 price);

    event NewAdminAddress(address admin);
    event NewBufferAndIntervalSeconds(uint256 bufferSeconds, uint256 intervalSeconds);
    event NewMinBetAmount(uint256 indexed epoch, uint256 minBetAmount);

    event NewOperatorAddress(address operator);
    event NewOracle(address oracle, address token);
    event NewOracleUpdateAllowance(uint256 oracleUpdateAllowance);
    event TokenAdded(address token, address oracle);
    event TokenRemoved(address token, address oracle);

    event Pause(uint256 indexed epoch);

    event StartRound(uint256 indexed epoch);
    event TokenRecovery(address indexed token, uint256 amount);
    event TreasuryClaim(uint256 amount);
    event Unpause(uint256 indexed epoch);

    modifier onlyAdmin() {
        require(msg.sender == adminAddress, "Not admin");
        _;
    }

    modifier onlyAdminOrOperator() {
        require(msg.sender == adminAddress || msg.sender == operatorAddress, "Not operator/admin");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operatorAddress, "Not operator");
        _;
    }

    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    /**
     * @notice Constructor
     * @param _adminAddress: admin address
     * @param _operatorAddress: operator address
     * @param _intervalSeconds: number of time within an interval
     * @param _bufferSeconds: buffer of time for resolution of price
     * @param _minBetAmount: minimum bet amounts (in wei)
     * @param _oracleUpdateAllowance: oracle update allowance
     */
    constructor(
        address _adminAddress,
        address _operatorAddress,
        uint256 _intervalSeconds,
        uint256 _bufferSeconds,
        uint256 _minBetAmount,
        uint256 _oracleUpdateAllowance
    ) {

        adminAddress = _adminAddress;
        operatorAddress = _operatorAddress;
        intervalSeconds = _intervalSeconds;
        bufferSeconds = _bufferSeconds;
        minBetAmount = _minBetAmount;
        oracleUpdateAllowance = _oracleUpdateAllowance;
    }
    
    function addTokens(address[] memory _tokens, address[] memory _oracles) external whenNotPaused onlyAdmin{
        for (uint i = 0; i < _tokens.length; i++){
            require(_tokens[i] != address(0) && _oracles[i] != address(0), "Predictoin: Cannot add a zero address");
            require( address(oracles[_tokens[i]]) == address(0), "Predictoin: Cannot readd a token" );
            tokens.push(_tokens[i]);
            oracles[_tokens[i]] = AggregatorV3Interface(_oracles[i]);
            emit TokenAdded(_tokens[i], _oracles[i]);
        }
    }
    
    function removeTokens(uint[] memory _ids) external whenNotPaused onlyAdmin{
        for (uint i = 0; i < _ids.length; i++){
            require(tokens[_ids[i]] != address(0), "Token not predictable");
            tokens[_ids[i]] = tokens[tokens.length-1];
            tokens.pop();
            delete oracles[tokens[_ids[i]]];
            emit TokenRemoved(tokens[_ids[i]], address(oracles[tokens[_ids[i]]]));  
        }
    }
    
    function getTokens() public view returns(address[] memory){
        return tokens;
    }

    /**
     * @notice Bet bear position
     * @param epoch: epoch
     */
    function betBear(uint256 epoch, address token) external payable whenNotPaused nonReentrant notContract {
        require(epoch == currentEpoch, "Bet is too early/late");
        require(_bettable(epoch), "Round not bettable");
        require(ledger[epoch][msg.sender].amount == 0, "Can only bet once per round");
        require(address(oracles[token]) != address(0), "Can't predict for token");

        // Update round data
        uint256 amount = minBetAmount;
        pred.safeTransferFrom(msg.sender, address(this), amount);
        Round storage round = rounds[epoch];
        round.totalAmount = round.totalAmount + amount;

        // Update user data
        BetInfo storage betInfo = ledger[epoch][msg.sender];
        betInfo.position = Position.Bear;
        betInfo.amount = amount;
        betInfo.token = token;
        userRounds[msg.sender].push(epoch);

        emit BetBear(msg.sender, epoch, amount);
    }

    /**
     * @notice Bet bull position
     * @param epoch: epoch
     */
    function betBull(uint256 epoch, address token) external payable whenNotPaused nonReentrant notContract {
        require(epoch == currentEpoch, "Bet is too early/late");
        require(_bettable(epoch), "Round not bettable");
        require(ledger[epoch][msg.sender].amount == 0, "Can only bet once per round");
        require(address(oracles[token]) != address(0), "Can't predict for token");

        // Update round data
        uint256 amount = minBetAmount;
        pred.safeTransferFrom(msg.sender, address(this), amount);
        Round storage round = rounds[epoch];
        round.totalAmount = round.totalAmount + amount;

        // Update user data
        BetInfo storage betInfo = ledger[epoch][msg.sender];
        betInfo.position = Position.Bull;
        betInfo.amount = amount;
        betInfo.token = token;
        userRounds[msg.sender].push(epoch);

        emit BetBull(msg.sender, epoch, amount);
    }

    /**
     * @notice Claim refund for an array of epochs
     * @param epochs: array of epochs
     */
    function claim(uint256[] calldata epochs) external nonReentrant notContract {
        uint256 reward; // Initializes reward

        for (uint256 i = 0; i < epochs.length; i++) {
            require(rounds[epochs[i]].startTimestamp != 0, "Round has not started");
            require(block.timestamp > rounds[epochs[i]].endTimestamp, "Round has not ended");
            require(!rounds[epochs[i]].oraclesCalled, "Oracles not called");
            require(refundable(epochs[i], msg.sender), "Not eligible for refund");

            ledger[epochs[i]][msg.sender].claimed = true;
            reward += minBetAmount;

            emit Claim(msg.sender, epochs[i], minBetAmount);
        }

        pred.safeTransfer(msg.sender, reward);
    }
    
    
    function startRound() external whenNotPaused onlyOperator {
        currentEpoch = currentEpoch + 1;
        if( currentEpoch > 1){
            _safeStartRound(currentEpoch);            
        }
        else{
            _startRound(currentEpoch);
        }
        _setStartPrices();   
    }
    
    function endRound() external whenNotPaused onlyOperator {
        _safeEndRound();
        treasuryAmount += rounds[currentEpoch].totalAmount;
    }

    
    /**
     * @notice called by the admin to pause, triggers stopped state
     * @dev Callable by admin or operator
     */
    function pause() external whenNotPaused onlyAdminOrOperator {
        _pause();

        emit Pause(currentEpoch);
    }

    /**
     * @notice Claim all rewards in treasury
     * @dev Callable by admin
     */
    function claimTreasury() external nonReentrant onlyAdmin {
        uint256 currentTreasuryAmount = treasuryAmount;
        treasuryAmount = 0;
        pred.transfer(adminAddress, treasuryAmount);

        emit TreasuryClaim(currentTreasuryAmount);
    }

    /**
     * @notice called by the admin to unpause, returns to normal state
     */
    function unpause() external whenPaused onlyAdmin {
        _unpause();

        emit Unpause(currentEpoch);
    }

    /**
     * @notice Set buffer and interval (in seconds)
     * @dev Callable by admin
     */
    function setBufferAndIntervalSeconds(uint256 _bufferSeconds, uint256 _intervalSeconds)
        external
        whenPaused
        onlyAdmin
    {
        require(_bufferSeconds < _intervalSeconds, "bufferSeconds must be inferior to intervalSeconds");
        bufferSeconds = _bufferSeconds;
        intervalSeconds = _intervalSeconds;

        emit NewBufferAndIntervalSeconds(_bufferSeconds, _intervalSeconds);
    }

    /**
     * @notice Set minBetAmount
     * @dev Callable by admin
     */
    function setMinBetAmount(uint256 _minBetAmount) external whenPaused onlyAdmin {
        require(_minBetAmount != 0, "Must be superior to 0");
        minBetAmount = _minBetAmount;

        emit NewMinBetAmount(currentEpoch, minBetAmount);
    }

    /**
     * @notice Set operator address
     * @dev Callable by admin
     */
    function setOperator(address _operatorAddress) external onlyAdmin {
        require(_operatorAddress != address(0), "Cannot be zero address");
        operatorAddress = _operatorAddress;

        emit NewOperatorAddress(_operatorAddress);
    }

    /**
     * @notice Set token oracle address
     * @dev Callable by admin
     */
    function setOracles(address[] memory _tokens, address[] memory _oracles) external whenPaused onlyAdmin {
        for (uint i; i < _tokens.length; i++){
            require(_oracles[i] != address(0), "Cannot be zero address");
            require(address(oracles[_tokens[i]]) != address(0), "Token not predictable");
            //oracleLatestRoundId = 0;
            oracles[_tokens[i]] = AggregatorV3Interface(_oracles[i]);
    
            // Dummy check to make sure the interface implements this function properly
            oracles[_tokens[i]].latestRoundData();
    
            emit NewOracle(_oracles[i], _tokens[i]);   
        }
    }

    /**
     * @notice Set oracle update allowance
     * @dev Callable by admin
     */
    function setOracleUpdateAllowance(uint256 _oracleUpdateAllowance) external whenPaused onlyAdmin {
        oracleUpdateAllowance = _oracleUpdateAllowance;

        emit NewOracleUpdateAllowance(_oracleUpdateAllowance);
    }


    /**
     * @notice It allows the owner to recover tokens sent to the contract by mistake
     * @param _token: token address
     * @param _amount: token amount
     * @dev Callable by owner
     */
    function recoverToken(address _token, uint256 _amount) external onlyOwner {
        require( _token != address(pred), "Pred cannot be recovered");
        IERC20(_token).safeTransfer(address(msg.sender), _amount);

        emit TokenRecovery(_token, _amount);
    }

    /**
     * @notice Set admin address
     * @dev Callable by owner
     */
    function setAdmin(address _adminAddress) external onlyOwner {
        require(_adminAddress != address(0), "Cannot be zero address");
        adminAddress = _adminAddress;

        emit NewAdminAddress(_adminAddress);
    }
    
    function getRound(uint _round) external view 
        returns(
            uint256 epoch,
            uint256 startTimestamp,
            uint256 endTimestamp,
            uint256 totalAmount,
            bool oraclesCalled,
            address[] memory _tokens,
            int256[] memory startPrices,
            int256[] memory endPrices,
            uint256[] memory startOracleIds,
            uint256[] memory endOracleIds
        )
    {
        epoch = _round;
        Round storage round = rounds[_round];
        startTimestamp = round.startTimestamp;
        endTimestamp = round.endTimestamp;
        totalAmount = round.totalAmount;
        oraclesCalled = round.oraclesCalled;
        _tokens = getTokens();
        startPrices = new int256[](_tokens.length);
        endPrices = new int256[](_tokens.length);
        startOracleIds = new uint256[](_tokens.length);
        endOracleIds = new uint256[](_tokens.length);
        
        for ( uint i=0; i< _tokens.length; i++){
            address token = _tokens[i];
            startPrices[i] = (round.startPrices[token]);
            endPrices[i] = (round.endPrices[token]);
            startOracleIds[i] = (round.startOracleIds[token]);
            endOracleIds[i] = (round.endOracleIds[token]);
        }
    }

    /**
     * @notice Returns round epochs and bet information for a user that has participated
     * @param user: user address
     * @param cursor: cursor
     * @param size: size
     */
    function getUserRounds(
        address user,
        uint256 cursor,
        uint256 size
    )
        external
        view
        returns (
            uint256[] memory,
            BetInfo[] memory,
            uint256
        )
    {
        uint256 length = size;

        if (length > userRounds[user].length - cursor) {
            length = userRounds[user].length - cursor;
        }

        uint256[] memory values = new uint256[](length);
        BetInfo[] memory betInfo = new BetInfo[](length);

        for (uint256 i = 0; i < length; i++) {
            values[i] = userRounds[user][cursor + i];
            betInfo[i] = ledger[values[i]][user];
        }

        return (values, betInfo, cursor + length);
    }

    /**
     * @notice Returns round epochs length
     * @param user: user address
     */
    function getUserRoundsLength(address user) external view returns (uint256) {
        return userRounds[user].length;
    }


    /**
     * @notice Get the refundable stats of specific epoch and user account
     * @param epoch: epoch
     * @param user: user address
     */
    function refundable(uint256 epoch, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[epoch][user];
        Round storage round = rounds[epoch];
        return
            !round.oraclesCalled &&
            !betInfo.claimed &&
            block.timestamp > round.endTimestamp + bufferSeconds &&
            betInfo.amount != 0;
    }
    
    function _setStartPrices() internal{
        Round storage round = rounds[currentEpoch];
        for (uint i; i < tokens.length; i++){
            address token = tokens[i];
            (uint80 currentRoundId, int256 currentPrice) = _getPriceFromOracle(oracles[token]);
            round.startPrices[token] = currentPrice;
            round.startOracleIds[token] = currentRoundId;
        }
    }
    
    function _setEndPrices() internal{
        Round storage round = rounds[currentEpoch];
        for (uint i; i < tokens.length; i++){
            address token = tokens[i];
            (uint80 currentRoundId, int256 currentPrice) = _getPriceFromOracle(oracles[token]);
            round.endPrices[token] = currentPrice;
            round.endOracleIds[token] = currentRoundId;
        }
    }


    /**
     * @notice End round
     */
    function _safeEndRound() internal {
        require(rounds[currentEpoch].startTimestamp != 0, "Can only end round after round has started");
        require(block.timestamp >= rounds[currentEpoch].endTimestamp, "Can only end round after closeTimestamp");
        require(
            block.timestamp <= rounds[currentEpoch].endTimestamp + bufferSeconds,
            "Can only end round within bufferSeconds"
        );
        _setEndPrices();
    }

    /**
     * @notice Start round
     * Previous round n-2 must end
     * @param epoch: epoch
     */
    function _safeStartRound(uint256 epoch) internal {
        require(rounds[epoch - 1].endTimestamp != 0, "Can only start round after round n-1 has ended");
        require(
            block.timestamp >= rounds[epoch - 1].endTimestamp,
            "Can only start new round after round n-1 endTimestamp"
        );
        _startRound(epoch);
    }

    /**
     * @notice Start round
     * Previous round n-2 must end
     * @param epoch: epoch
     */
    function _startRound(uint256 epoch) internal {
        Round storage round = rounds[epoch];
        round.startTimestamp = block.timestamp;
        round.endTimestamp = block.timestamp + intervalSeconds;
        round.epoch = epoch;
        round.totalAmount = 0;

        emit StartRound(epoch);
    }

    /**
     * @notice Determine if a round is valid for receiving bets
     * Round must have started and locked
     * Current timestamp must be within startTimestamp and closeTimestamp
     */
    function _bettable(uint256 epoch) internal view returns (bool) {
        return
            rounds[epoch].startTimestamp != 0 &&
            block.timestamp > rounds[epoch].startTimestamp &&
            block.timestamp < rounds[epoch].startTimestamp + 1 hours; 
    }

    /**
     * @notice Get latest recorded price from oracle
     * If it falls below allowed buffer or has not updated, it would be invalid.
     */
    function _getPriceFromOracle(AggregatorV3Interface oracle) internal view returns (uint80, int256) {
        uint256 leastAllowedTimestamp = block.timestamp + oracleUpdateAllowance;
        (uint80 roundId, int256 price, , uint256 timestamp, ) = oracle.latestRoundData();
        require(timestamp <= leastAllowedTimestamp, "Oracle update exceeded max timestamp allowance");
        require(
            uint256(roundId) > oracleLatestRoundId,
            "Oracle update roundId must be larger than oracleLatestRoundId"
        );
        return (roundId, price);
    }

    /**
     * @notice Returns true if `account` is a contract.
     * @param account: account address
     */
    function _isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }
}