// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPositionInfo, CLPositionInfoLibrary} from "infinity-periphery/src/pool-cl/libraries/CLPositionInfoLibrary.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint128} from "infinity-core/src/pool-cl/libraries/FixedPoint128.sol";
import {Tick} from "infinity-core/src/pool-cl/libraries/Tick.sol";
import {CLPosition} from "infinity-core/src/pool-cl/libraries/CLPosition.sol";

import {IHuksFunLPLocker} from "../interfaces/IHuksFunLPLocker.sol";

/// @title HuksFunFeeViewer
/// @notice Helper contract to view pending fees for HuksFun positions on PancakeSwap Infinity
contract HuksFunFeeViewer {
    using PoolIdLibrary for PoolKey;
    using CLPositionInfoLibrary for CLPositionInfo;

    ICLPositionManager public immutable clPositionManager;
    ICLPoolManager public immutable clPoolManager;
    IHuksFunLPLocker public immutable lpLocker;

    uint256 public constant CREATOR_FEE_BPS = 8000; // 80%
    uint256 public constant BPS = 10000;

    struct PendingFees {
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        uint256 creatorAmount0;
        uint256 creatorAmount1;
        uint256 adminAmount0;
        uint256 adminAmount1;
    }

    constructor(address _clPositionManager, address _clPoolManager, address _lpLocker) {
        clPositionManager = ICLPositionManager(_clPositionManager);
        clPoolManager = ICLPoolManager(_clPoolManager);
        lpLocker = IHuksFunLPLocker(_lpLocker);
    }

    /// @notice Get pending fees for a token's locked LP position
    /// @param token The token address
    /// @return fees The pending fees breakdown
    function getPendingFees(address token) external view returns (PendingFees memory fees) {
        // Get position from locker
        (uint256 positionId, ) = lpLocker.getPosition(token);
        if (positionId == 0) return fees;

        // Get pool key and position info
        (PoolKey memory poolKey, CLPositionInfo posInfo) = clPositionManager.getPoolAndPositionInfo(positionId);

        fees.token0 = Currency.unwrap(poolKey.currency0);
        fees.token1 = Currency.unwrap(poolKey.currency1);

        int24 tickLower = posInfo.tickLower();
        int24 tickUpper = posInfo.tickUpper();

        // Get position liquidity
        uint128 liquidity = clPositionManager.getPositionLiquidity(positionId);
        if (liquidity == 0) return fees;

        // Get pool state
        PoolId poolId = poolKey.toId();

        // Compute fee growth inside from globals + tick outside values
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = _getFeeGrowthInside(poolId, tickLower, tickUpper);

        // Get position's last recorded fee growth
        CLPosition.Info memory position = clPoolManager.getPosition(
            poolId, address(clPositionManager), tickLower, tickUpper, bytes32(positionId)
        );
        uint256 feeGrowthInside0LastX128 = position.feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128 = position.feeGrowthInside1LastX128;

        // Calculate pending fees
        fees.amount0 = FullMath.mulDiv(
            feeGrowthInside0X128 - feeGrowthInside0LastX128,
            liquidity,
            FixedPoint128.Q128
        );
        fees.amount1 = FullMath.mulDiv(
            feeGrowthInside1X128 - feeGrowthInside1LastX128,
            liquidity,
            FixedPoint128.Q128
        );

        // Calculate creator/admin split
        fees.creatorAmount0 = (fees.amount0 * CREATOR_FEE_BPS) / BPS;
        fees.creatorAmount1 = (fees.amount1 * CREATOR_FEE_BPS) / BPS;
        fees.adminAmount0 = fees.amount0 - fees.creatorAmount0;
        fees.adminAmount1 = fees.amount1 - fees.creatorAmount1;
    }

    /// @notice Get pending fees for multiple tokens
    /// @param tokens Array of token addresses
    /// @return fees Array of pending fees
    function getPendingFeesBatch(address[] calldata tokens) external view returns (PendingFees[] memory fees) {
        fees = new PendingFees[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            fees[i] = this.getPendingFees(tokens[i]);
        }
    }

    /// @dev Compute fee growth inside a tick range using pool manager view functions
    function _getFeeGrowthInside(
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        (, int24 tickCurrent,,) = clPoolManager.getSlot0(poolId);
        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = clPoolManager.getFeeGrowthGlobals(poolId);

        Tick.Info memory lower = clPoolManager.getPoolTickInfo(poolId, tickLower);
        Tick.Info memory upper = clPoolManager.getPoolTickInfo(poolId, tickUpper);

        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        unchecked {
            if (tickCurrent >= tickLower) {
                feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
                feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
            } else {
                feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
                feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
            }

            uint256 feeGrowthAbove0X128;
            uint256 feeGrowthAbove1X128;
            if (tickCurrent < tickUpper) {
                feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
                feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
            } else {
                feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
                feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
            }

            feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
            feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
        }
    }
}