// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CCIPReceiver } from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { LendingPool } from "./LendingPool.sol";

/// @notice Lets a user deposit LendingPool collateral that originates on another chain, using a single
/// CCIP "programmable token transfer": the collateral token and the depositor's address travel together
/// in one CCIP message, and `_ccipReceive` deposits the arrived tokens into the local LendingPool on that
/// user's behalf. The same contract is deployed on every connected chain, each instance wired to its own
/// local router and LendingPool, and each peer (chain selector, sender address) pair must be explicitly
/// allowlisted by the owner before messages from it are trusted.
contract CrossChainCollateralRouter is CCIPReceiver, Ownable {
    using SafeERC20 for IERC20;

    LendingPool public immutable pool;
    IERC20 public immutable collateralToken;
    IERC20 public immutable linkToken;

    /// @notice Gas Automation-style callback budget for `_ccipReceive` on the destination chain.
    uint256 public constant CCIP_GAS_LIMIT = 300_000;

    mapping(uint64 chainSelector => bool) public allowedDestinationChain;
    mapping(uint64 chainSelector => mapping(address sender => bool)) public allowedSource;

    event CollateralSent(
        uint64 indexed destinationChainSelector, address indexed user, uint256 amount, bytes32 messageId
    );
    event CollateralReceived(uint64 indexed sourceChainSelector, address indexed user, uint256 amount);
    event DestinationChainAllowed(uint64 indexed chainSelector, bool allowed);
    event SourceAllowed(uint64 indexed chainSelector, address indexed sender, bool allowed);

    error ZeroAmount();
    error DestinationNotAllowed(uint64 chainSelector);
    error SourceNotAllowed(uint64 chainSelector, address sender);
    error UnexpectedTokenPayload(uint256 tokenCount);
    error UnexpectedToken(address token);

    constructor(address initialOwner, address router, address link, LendingPool pool_, IERC20 collateralToken_)
        CCIPReceiver(router)
        Ownable(initialOwner)
    {
        linkToken = IERC20(link);
        pool = pool_;
        collateralToken = collateralToken_;
    }

    function setDestinationChainAllowed(uint64 chainSelector, bool allowed) external onlyOwner {
        allowedDestinationChain[chainSelector] = allowed;
        emit DestinationChainAllowed(chainSelector, allowed);
    }

    function setSourceAllowed(uint64 chainSelector, address sender, bool allowed) external onlyOwner {
        allowedSource[chainSelector][sender] = allowed;
        emit SourceAllowed(chainSelector, sender, allowed);
    }

    /// @notice Locks `amount` of collateral token from the caller and ships it, together with the
    /// caller's address, to the CrossChainCollateralRouter deployed at `destinationRouter` on
    /// `destinationChainSelector`. CCIP fees are paid in LINK, pulled from the caller.
    function depositCollateralCrossChain(uint64 destinationChainSelector, address destinationRouter, uint256 amount)
        external
        returns (bytes32 messageId)
    {
        if (amount == 0) revert ZeroAmount();
        if (!allowedDestinationChain[destinationChainSelector]) {
            revert DestinationNotAllowed(destinationChainSelector);
        }

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({ token: address(collateralToken), amount: amount });

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(destinationRouter),
            data: abi.encode(msg.sender),
            tokenAmounts: tokenAmounts,
            feeToken: address(linkToken),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({ gasLimit: CCIP_GAS_LIMIT, allowOutOfOrderExecution: true })
            )
        });

        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(destinationChainSelector, message);

        linkToken.safeTransferFrom(msg.sender, address(this), fee);
        linkToken.forceApprove(address(router), fee);
        collateralToken.forceApprove(address(router), amount);

        messageId = router.ccipSend(destinationChainSelector, message);
        emit CollateralSent(destinationChainSelector, msg.sender, amount, messageId);
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        address sender = abi.decode(message.sender, (address));
        if (!allowedSource[message.sourceChainSelector][sender]) {
            revert SourceNotAllowed(message.sourceChainSelector, sender);
        }
        if (message.destTokenAmounts.length != 1) revert UnexpectedTokenPayload(message.destTokenAmounts.length);
        if (message.destTokenAmounts[0].token != address(collateralToken)) {
            revert UnexpectedToken(message.destTokenAmounts[0].token);
        }

        address user = abi.decode(message.data, (address));
        uint256 amount = message.destTokenAmounts[0].amount;

        emit CollateralReceived(message.sourceChainSelector, user, amount);

        collateralToken.forceApprove(address(pool), amount);
        pool.depositCollateralFor(user, amount);
    }
}
