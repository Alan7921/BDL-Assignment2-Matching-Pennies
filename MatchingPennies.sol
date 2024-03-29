// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.9.0;

// @author Xin S2176116 at UoE 2021/10/28
contract MatchingPennies {
    // create a struct to store the releated info of each player
    struct player {
        // address of player
        address addr;
        // balance of player
        uint256 balance;
        //whether the user has joined the game
        bool joined;
        // whether this address is included in mapping or not
        bool used;       
        // commitment of player
        bytes32 commitment;
        // choice that player made from 0 or 1
        bytes1 choice;
        // whether the player has sent his/her commitment
        bool isCommitted;
        // whether the commitment matches the committed nonce and option player sent
        bool isValid;
        // whether this player has been verified
        bool verified;
    }

    // create an enum type to present the stage of current game
    enum State {
        waitPlayers,
        makeDecision,
        verification,
        announcement,
        roundover
    }

    //Game status Control
    State public gameState = State.waitPlayers;


    // use a map to store the details of players which would be more efficient than an player array
    mapping(address => player) public players;
    //array to record which address in which seat, seats[0] refers to player A
    //seats[1] refers to player B
    address[2] seats;


    // fee
    uint256 public constant JETTON = 1.0 ether; 
    //the least money needed to as jetton in the game   
    uint256 public constant HAND_FEE = 0.05 ether; 
    //would be taken when player deposits ether into contract
    uint256 public constant JOIN_FEE = 0.05 ether;
    //would be taken whenever a player join a game
    uint256 public constant ANNOUNCEMENT_FEE = 0.05 ether; 
    // a compensation for player who choose to annouce results
    uint256 public constant Expiration_FEE = 0.05 ether; 
    // reward for who end the expiration
    address owner; 
    // the organizer of this game contract
   

    //Fairness Concern
    uint wasteVariable; // would be used to realize fairness between players
    
    //Expiration
    uint public lastUpdatedTime; // record the timestamp updated in last time
    uint public timeLimit; // a limitation to each stage
    

    //Events
    event Winner(address winnerAddr, string message); 
    //record the address of winner in log
    event CheaterDetected (address cheaterAddr, string message);
    //record the address of cheater in log
    event AbnormalResult(string message);
    //record abnormal results like both cheated

    constructor(){
        owner = msg.sender; // asign the address of owner
        lastUpdatedTime = block.timestamp;
        timeLimit = 5 minutes;
    }
    
    /***
     * This method provides a function for players to deposit ether in this game.
     * @return Nothing.
     */
    function deposit() public payable {
        require(msg.value >= HAND_FEE, 
            "The deposit would take 0.05 ether as hand fee, please send at least 0.05 ether."
        );
        players[msg.sender].balance += msg.value - HAND_FEE;
        if(!players[msg.sender].used){
            players[msg.sender].addr = msg.sender; // record the address if new user deposits
            players[msg.sender].used = true;
        }
    }
    
    /***
     * This method provides a function for players to join the game.
     * If your balance is less than jetton + join fee (1.05 ether), please deposit first.
     * @param seatNumber either 0 or 1, which is the seat users want to choose to join the game.
     * @return Nothing.
     */
    function join(uint8 seatNumber) public {
        require(
            gameState == State.waitPlayers || gameState == State.roundover,
            "Game is ongoing, please wait for next round."
        );
        require(players[msg.sender].balance >= JETTON + JOIN_FEE, 
            "You do not have enough balance. "
            "To join the game, you need to ensure that you have at least 1.05 ether "
            "where the jetton is 1 ether and the 0.05 ether would be taken as a join fee."
        );           
        seatNumber %= 2; // make sure that the seatNumber is 0 or 1
        require(
            seats[seatNumber] == address(0),
            "Sorry, this seat has been occupied."
        );
        require(!players[msg.sender].joined, "Please do not repeat to join!");
        
        if (seats[0] == address(0) && seats[1] == address(0)) {
            for(uint64 i=0;i<6;i++){
                wasteVariable += i;  
            }// to make sure that first player pay equal gas fee as second player
        }

        players[msg.sender].joined = true;
        seats[seatNumber] = msg.sender;
        gameState = State.waitPlayers;

        if (seats[0] != address(0) && seats[1] != address(0)) {
            gameState = State.makeDecision;
            timeUpdate();
        }
    }

    /***
     * This method provides a function for players to quit the game.
     * For instance, if you do not want to wait anouther player or do not want to 
     * join next round of game, you can just quit the game.
     * @return Nothing.
     */    
    function quit() public{
        require(
            gameState == State.waitPlayers || 
            gameState == State.roundover,
            "Game is on going, you are not allowed to quit now."
        );
        require(
            msg.sender == seats[0] || msg.sender == seats[1],
            "You are not in the game."
            );
            
        if(msg.sender == seats[0]){
            delete seats[0];
        }else{
            delete seats[1];
        }
        players[msg.sender].joined = false;
    }

    /***
     * This method provides a function for players to send their commitment.
     * @param commitment, must be a 32-bytes hexadecimal inputs which is cuculated by nonce+0/1,
     * an example is "0x87c2d362de99f75a4f2755cdaaad2d11bf6cc65dc71356593c445535ff28f43d".
     * Please keep the original nonce and number committed for hash value.
     * You would be requested to provide this value to proof your commitment at next stage.
     * @return Nothing.
     */
    function sendCommitment(bytes32 commitment) public {
        require(
            !checkExpiration(),
            "Game is expired, who calls the endExpiration to end the expiration woul be rewarded."
        ); // make sure that the game has not expired
        require(
            gameState == State.makeDecision,
            "You are not allowed to send your commitment other than the second stage."
        );
        require(
            players[msg.sender].joined,
            "You do not have access to send commitment in the current game."
        );
        require(
            !players[msg.sender].isCommitted,
            "You have sent your commitment, you are not allowed to send it twice." 
            "Just wait for the commitment of other player."
        );

        players[msg.sender].commitment = commitment;
        players[msg.sender].isCommitted = true;
        
        if (players[seats[0]].isCommitted && players[seats[1]].isCommitted) {
            gameState = State.verification;
            timeUpdate(); // if both players have sent commitment, update the time
        }
    }

    /***
     * This method is used to verify the committed value from players.
     * Any player who could not provides a corresponding value 
     * which could be used to get an exactly same hash as they sent at last stage,
     * would be punished with a fine, and they would lose the game.
     * Besides, especially for playerA, 
     * if he sent a hash culculated from nounce + number other than 0 or 1, 
     * what he did would also be regarded as cheating behavior.
     * @param origin, a string that used to generate hash value at last stage,
     * an example:"9f74e042264bedfd27e031467271541dbb991696d1428527b6d9a0e5cc793f58big1".
     * @return Nothing.
     */
    function verify(string calldata origin) public {
        require(
            !checkExpiration(),
            "Game is expired, please call the endExpiration to restart it."
        );
        require(
            gameState == State.verification,
            "The game is not in the verification stage now."
        );
        require(
            players[msg.sender].joined,
            "You do not have access to send the committed value in the current game"
        );
        bytes32 temp = keccak256(abi.encodePacked(origin));
        players[msg.sender].choice = getChoice(origin);

        if (temp == players[msg.sender].commitment && 
            (players[msg.sender].choice == 0x31 || players[msg.sender].choice == 0x30)) 
        {   
            if(msg.sender != seats[1]){
                players[msg.sender].isValid = true;   
            }else{
                if(players[msg.sender].commitment != players[seats[0]].commitment){
                    players[msg.sender].isValid = true;     
                }
            }  
        } 
        
        players[msg.sender].verified = true;
        if (players[seats[0]].verified && players[seats[1]].verified) {
            gameState = State.announcement;
            timeUpdate();// if both players have revealed options, update the time
        }
    }

    /***
     * This method is used to export the result of game in this round.
     * @return Nothing.
     */
    function announcement() public {
        require(
            gameState == State.announcement,
            "The game of this round has not arrived its announcement stage."
        );
        players[msg.sender].balance += ANNOUNCEMENT_FEE; 
        // player who call this function would be rewarded
        gameState = State.roundover;
        timeUpdate();// if someone has annouced the result, update the time
        checkWinner();     
    }

    /***
     * This method is used to get the number from the original string players sent.
     * @param fullToken, a string that users used to generate hash.
     * @return a bytes1 value would be returned as the option of players.
     */
    function getChoice(string calldata fullToken) internal pure returns (bytes1) {
        bytes memory b = bytes(fullToken);
        bytes1 b1 = b[b.length - 1];
        return b1;
    } 

    /***
     * This method is used to update the time.
     * @return Nothing.
     */
    function timeUpdate() internal {
        lastUpdatedTime = block.timestamp;
    }

     /***
     * One player can claim that another player did not response in time to win the game.
     * @return Nothing.
     */   
    function timeOut() external {
        require (gameState != State.waitPlayers &&
        gameState != State.roundover,
        "If game expired at waiting players stage or roundover stage, "
        "please wait for the join of next player, it would update the timestamp."
        );
        require (checkExpiration(),
        "There is still time left, you could not claim time out."
        );
        require(
            players[msg.sender].joined,
            "You do not have access to claim time out."
        );
        if(gameState == State.makeDecision){
            require(players[msg.sender].isCommitted);
            if(msg.sender == seats[0]){
                winnerIsA();
            }else{
                winnerIsB();
            }
        }
        if(gameState == State.verification){
            require(players[msg.sender].verified);
            if(msg.sender == seats[0]){
                winnerIsA();
            }else{
                winnerIsB();
            }
        }
        dataReset();
        gameState = State.waitPlayers;
    }

     /***
     * This method is used to check whether the game is expired or not.
     * @return a bool type isExpired, true for expired, false for not.
     */ 
    function checkExpiration() public view returns (bool isExpired){
        if(block.timestamp >= lastUpdatedTime + timeLimit){
            return true;
        }else{
            return false;
        }
    }
 
     /***
     * This method is used to end the expiration.
     * Users who call this function would be rewarded with 0.1 ether.
     * @return nothing.
     */  
    function endExpiration() external {

        require(checkExpiration(), "Game is not expired");
        
        players[seats[0]].balance -= JOIN_FEE;
        players[seats[1]].balance -= JOIN_FEE;
        players[msg.sender].balance += Expiration_FEE;        
       
        if(gameState == State.makeDecision){
            if(players[seats[0]].isCommitted){
                 winnerIsA();
            }else if (players[seats[1]].isCommitted){
                 winnerIsB();
            }
        }
        if(gameState == State.verification){
            if(players[seats[0]].verified){
                winnerIsA();
            }else if(players[seats[1]].verified){
                winnerIsB();
            }
        } 
        if(gameState == State.announcement){
            announcement();
        }

        gameState = State.waitPlayers;
        dataReset();
    }

    /***
     * An internal function used to check the winner
     * @return Nothing.
     */
    function checkWinner() internal {
        
        if (!players[seats[0]].isValid && players[seats[1]].isValid) {
             emit CheaterDetected (seats[0], "Player A at this address cheated in this round.");             
             winnerIsB();
        } else if (players[seats[0]].isValid && !players[seats[1]].isValid) {
             emit CheaterDetected (seats[1], "Player B at this address cheated in this round.");             
             winnerIsA();
        } else if (players[seats[0]].isValid && players[seats[1]].isValid) {
            if (players[seats[0]].choice == players[seats[1]].choice) {
                 winnerIsB();
            } else {
                 winnerIsA();
            }            
        } else{
            emit AbnormalResult("Two sides cheated, No one wins in this round.");        
            emit CheaterDetected (seats[0], "Player A at this address cheated in this round.");
            emit CheaterDetected (seats[1], "Player B at this address cheated in this round.");
            noWinner();
        }
    }

    /***
     * An internal function used if playerB win the game.
     * @return Nothing.
     */
    function winnerIsB() internal {
        require(players[seats[0]].balance >= JETTON,
            "PlayerA do not have enough balance."
        );
        players[seats[0]].balance -= JETTON;
        players[seats[1]].balance += JETTON;
        
        emit Winner(seats[1], "Player B wins in this round.");
        
        dataReset();  
    }

    /***
     * An internal function used if playerA win the game.
     * @return Nothing.
     */
    function winnerIsA() internal {
        require(players[seats[1]].balance >= JETTON,
            "PlayerB do not have enough balance."
        );        
        players[seats[1]].balance -= JETTON;
        players[seats[0]].balance += JETTON;
        
        emit Winner(seats[0], "Player A wins in this round.");

        dataReset();
    }

    /***
     * An internal function used if both the two sides cheated in this round.
     * @return Nothing.
     */
    function noWinner() internal {
        players[seats[1]].balance = 0;
        players[seats[0]].balance = 0;
             
        dataReset();
    }

    /***
     * An internal function used to reset the status of players and game at the end of each round.
     * @return Nothing.
     */
    function dataReset() internal {
        
        players[seats[0]].joined = false;
        players[seats[0]].commitment = "0x00";
        players[seats[0]].choice = 0x00;
        players[seats[0]].isCommitted = false;
        players[seats[0]].isValid = false;
        players[seats[0]].verified = false;

        players[seats[1]].joined = false;
        players[seats[1]].commitment = "0x00";
        players[seats[1]].choice = 0x00;
        players[seats[1]].isCommitted = false;
        players[seats[1]].isValid = false;
        players[seats[1]].verified = false;

        delete seats[0];
        delete seats[1];
    }
    
    /***
     * This method allows players to check the state of game.
     * @return currentState.
     */
    function checkState() external view returns (string memory currentState) {
        if (gameState == State.waitPlayers){
            return "Waiting for players.";
        }else if (gameState == State.makeDecision){
            return "Please send your commitment.";
        }else if (gameState == State.verification){
            return "Please send salt and option.";
        }else if (gameState == State.announcement){
            return "Please call the announcement.";
        }else {
            return "Game over in this round.";
        }
    }

    /***
     * This method allows players to withdraw their money from contract 
     * at either waitPlayers stage or roundover stage.
     * Money would be sent to the account of msg.sender.
     * @return Nothing.
     */
    function withdraw() public {
        require(
            gameState == State.roundover || gameState == State.waitPlayers,
            "You can only withdraw your money at the waitPlayers stage "
            "and at the roundover stage."
        );
        require(
            players[msg.sender].balance > 0,
            "You do not have any ether in you banlance."
        );
        require(
            players[msg.sender].joined == false,
            "You have just joined a game, please withdraw you money after this round."
        );

        uint256 amount = players[msg.sender].balance;
        players[msg.sender].balance = 0;
        payable(msg.sender).transfer(amount);
    }
}