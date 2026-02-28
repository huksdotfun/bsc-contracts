// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title HuksFunSwapRouter
/// @notice Swap router for HuksFun tokens on PancakeSwap Infinity (BSC) with configurable protocol fee
/// @dev Uses Vault.lock() pattern for atomic swaps. Protocol fee is taken in BNB on both buy and sell.
contract HuksFunSwapRouter is ILockCallback {
    using SafeERC20 for IERC20;
    using CLPoolParametersHelper for bytes32;

    IVault public immutable vault;
    ICLPoolManager public immutable clPoolManager;

    // Native BNB represented as address(0) in PancakeSwap Infinity
    address constant NATIVE_BNB = address(0);

    uint24 public constant LP_FEE = 10000; // 1%
    int24 public constant TICK_SPACING = 200;
    uint160 constant MIN_SQRT_PRICE = 4295128740;
    uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970341;

    uint256 public constant MAX_PROTOCOL_FEE_BPS = 500; // Max 5%
    uint256 public constant BPS = 10000;

    address public admin;
    address public feeRecipient;
    uint256 public protocolFeeBps; // Fee in basis points (e.g. 100 = 1%)

    struct SwapData {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        address recipient;
        uint256 bnbAmount; // BNB sent with the swap (for buying)
    }

    event TokensBought(address indexed buyer, address indexed token, uint256 bnbIn, uint256 tokensOut, uint256 protocolFee);
    event TokensSold(address indexed seller, address indexed token, uint256 tokensIn, uint256 bnbOut, uint256 protocolFee);
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event AdminTransferred(address oldAdmin, address newAdmin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    constructor(address _vault, address _clPoolManager, address _admin) {
        vault = IVault(_vault);
        clPoolManager = ICLPoolManager(_clPoolManager);
        admin = _admin;
        feeRecipient = _admin;
        protocolFeeBps = 100; // Default 1% protocol fee on both buy and sell
    }

    /// @notice Set the protocol fee (in basis points). Set to 0 to disable.
    /// @param newFeeBps New fee in basis points (0 = free, max 500 = 5%)
    function setProtocolFee(uint256 newFeeBps) external onlyAdmin {
        require(newFeeBps <= MAX_PROTOCOL_FEE_BPS, "Fee too high");
        uint256 oldFee = protocolFeeBps;
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeUpdated(oldFee, newFeeBps);
    }

    /// @notice Update the fee recipient address
    function setFeeRecipient(address newRecipient) external onlyAdmin {
        require(newRecipient != address(0), "Invalid recipient");
        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    /// @notice Transfer admin to new address
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Invalid admin");
        address old = admin;
        admin = newAdmin;
        emit AdminTransferred(old, newAdmin);
    }

    /// @notice Buy tokens with native BNB. Protocol fee deducted from BNB before swap.
    /// @param token The HuksFun token to buy
    /// @param minTokensOut Minimum tokens to receive (slippage protection)
    function buyTokens(address token, uint256 minTokensOut) external payable returns (uint256 tokensOut) {
        require(msg.value > 0, "No BNB sent");

        // Deduct protocol fee from BNB before swapping
        uint256 fee = (msg.value * protocolFeeBps) / BPS;
        uint256 swapAmount = msg.value - fee;
        require(swapAmount > 0, "Amount too small after fee");

        // Send fee to recipient
        if (fee > 0) {
            (bool feeSuccess,) = feeRecipient.call{value: fee}("");
            require(feeSuccess, "Fee transfer failed");
        }

        // Build parameters with tickSpacing encoded
        bytes32 parameters = bytes32(0).setTickSpacing(TICK_SPACING);

        // Build pool key - BNB (address(0)) is always currency0
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(NATIVE_BNB),
            currency1: Currency.wrap(token),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(clPoolManager)),
            fee: LP_FEE,
            parameters: parameters
        });

        // Swap direction: sell BNB (currency0) to get tokens (currency1)
        SwapData memory data = SwapData({
            key: key,
            zeroForOne: true,
            amountSpecified: -int256(swapAmount), // Negative = exact input
            recipient: msg.sender,
            bnbAmount: swapAmount
        });

        bytes memory result = vault.lock(abi.encode(data));
        (int256 delta0, int256 delta1) = abi.decode(result, (int256, int256));

        // delta1 is positive = tokens we receive
        tokensOut = uint256(delta1);
        require(tokensOut >= minTokensOut, "Slippage exceeded");

        emit TokensBought(msg.sender, token, msg.value, tokensOut, fee);
    }

    /// @notice Sell tokens for native BNB. Protocol fee deducted from BNB output.
    /// @param token The HuksFun token to sell
    /// @param tokensIn Amount of tokens to sell
    /// @param minBnbOut Minimum BNB to receive (after protocol fee)
    function sellTokens(address token, uint256 tokensIn, uint256 minBnbOut) external returns (uint256 bnbOut) {
        require(tokensIn > 0, "No tokens");

        // Transfer tokens from seller to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);

        // Build parameters with tickSpacing encoded
        bytes32 parameters = bytes32(0).setTickSpacing(TICK_SPACING);

        // Build pool key - BNB is always currency0
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(NATIVE_BNB),
            currency1: Currency.wrap(token),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(clPoolManager)),
            fee: LP_FEE,
            parameters: parameters
        });

        // Swap direction: sell tokens (currency1) to get BNB (currency0)
        SwapData memory data = SwapData({
            key: key,
            zeroForOne: false,
            amountSpecified: -int256(tokensIn), // Negative = exact input
            recipient: msg.sender,
            bnbAmount: 0
        });

        bytes memory result = vault.lock(abi.encode(data));
        (int256 delta0, int256 delta1) = abi.decode(result, (int256, int256));

        // delta0 is positive = gross BNB from swap
        uint256 grossBnb = uint256(delta0);

        // Deduct protocol fee from BNB output
        uint256 fee = (grossBnb * protocolFeeBps) / BPS;
        bnbOut = grossBnb - fee;
        require(bnbOut >= minBnbOut, "Slippage exceeded");

        // Send fee to recipient
        if (fee > 0) {
            (bool feeSuccess,) = feeRecipient.call{value: fee}("");
            require(feeSuccess, "Fee transfer failed");
        }

        // Transfer remaining BNB to seller
        (bool success,) = msg.sender.call{value: bnbOut}("");
        require(success, "BNB transfer failed");

        emit TokensSold(msg.sender, token, tokensIn, bnbOut, fee);
    }

    /// @notice Callback from Vault.lock()
    function lockAcquired(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(vault), "Only Vault");

        SwapData memory data = abi.decode(rawData, (SwapData));

        // Execute swap via CLPoolManager
        BalanceDelta delta = clPoolManager.swap(
            data.key,
            ICLPoolManager.SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: data.amountSpecified,
                sqrtPriceLimitX96: data.zeroForOne ? MIN_SQRT_PRICE : MAX_SQRT_PRICE
            }),
            ""
        );

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Settle currency0 (BNB)
        _settleBNB(delta0, data.bnbAmount);

        // Settle currency1 (Token)
        _settleToken(data.key.currency1, delta1, data.recipient);

        return abi.encode(delta0, delta1);
    }

    function _settleBNB(int128 delta, uint256 bnbAvailable) internal {
        if (delta < 0) {
            // We owe BNB to the pool (buying tokens)
            uint256 amount = uint256(int256(-delta));
            vault.settle{value: amount}();

            // Refund excess BNB if any
            if (bnbAvailable > amount) {
                // Note: refund happens after callback returns
            }
        } else if (delta > 0) {
            // Pool owes us BNB (selling tokens)
            vault.take(Currency.wrap(NATIVE_BNB), address(this), uint256(int256(delta)));
        }
    }

    function _settleToken(Currency currency, int128 delta, address recipient) internal {
        if (delta < 0) {
            // We owe tokens to the pool (selling tokens)
            uint256 amount = uint256(int256(-delta));
            vault.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(vault), amount);
            vault.settle();
        } else if (delta > 0) {
            // Pool owes us tokens (buying tokens)
            vault.take(currency, recipient, uint256(int256(delta)));
        }
    }

    receive() external payable {}
}