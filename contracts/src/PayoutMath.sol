// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PayoutMath
/// @notice Fixed-point reimplementation of the pricing engine's payout formula.
/// @dev This is the one piece of logic that exists in two languages. The Python
///      reference lives in `pricing/src/parametric/policy.py`; the shared cases
///      in `test/vectors.json` are generated from it and checked here. Any change
///      to the formula has to land in both places or the vector test fails.
///
///      Units, fixed once and used everywhere:
///        - rainfall  : hundredths of a millimetre (mm * 100)
///        - weight    : basis points (100% = 10_000)
///        - money     : token base units (USDC = 6 decimals)
library PayoutMath {
    uint256 internal constant BPS = 10_000;

    error ExitNotBelowTrigger(uint32 triggerMmX100, uint32 exitMmX100);

    /// @notice Share of a phase's exposure that pays out, in basis points.
    /// @dev Linear between trigger and exit:
    ///        clamp((trigger - observed) / (trigger - exit), 0, 1)
    ///      Returns 0 at or above trigger, BPS at or below exit.
    function payoutFractionBps(uint32 triggerMmX100, uint32 exitMmX100, uint32 observedMmX100)
        internal
        pure
        returns (uint256)
    {
        if (exitMmX100 >= triggerMmX100) {
            revert ExitNotBelowTrigger(triggerMmX100, exitMmX100);
        }
        if (observedMmX100 >= triggerMmX100) return 0;
        if (observedMmX100 <= exitMmX100) return BPS;

        // 0 < (trigger - observed) < (trigger - exit), so this is a proper
        // fraction and the multiplication cannot overflow a uint256.
        unchecked {
            uint256 numerator = uint256(triggerMmX100 - observedMmX100) * BPS;
            return numerator / uint256(triggerMmX100 - exitMmX100);
        }
    }

    /// @notice Payout for a single phase, in token base units.
    /// @dev Rounds down. The pricing engine carries floats and rounds at the
    ///      boundary; both truncate toward zero, so the vectors agree.
    function phasePayout(
        uint256 sumInsuredUnits,
        uint16 weightBps,
        uint32 triggerMmX100,
        uint32 exitMmX100,
        uint32 observedMmX100
    ) internal pure returns (uint256) {
        uint256 fraction = payoutFractionBps(triggerMmX100, exitMmX100, observedMmX100);
        if (fraction == 0) return 0;

        // Multiply before dividing to keep precision; divide by BPS twice
        // (once for weight, once for fraction) in a single denominator.
        return (sumInsuredUnits * uint256(weightBps) * fraction) / (BPS * BPS);
    }
}
