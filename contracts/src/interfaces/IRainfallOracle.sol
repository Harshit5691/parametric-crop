// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Source of settled rainfall observations.
/// @dev The trust assumption of the whole system, and the pitch should say so.
///      At launch we operate the oracle: it fetches 2-3 independent feeds,
///      takes the median, and publishes inputs alongside the result so the
///      number is auditable even while the operator is trusted. The
///      decentralisation path is to move this behind Chainlink Functions or a
///      multi-signer attestation set.
interface IRainfallOracle {
    /// @notice Cumulative rainfall for a phase window, in hundredths of a mm.
    /// @param policyId Policy the observation belongs to.
    /// @param phaseIndex Index of the phase within that policy.
    /// @return observedMmX100 Settled cumulative rainfall.
    /// @return settledAt Timestamp the value was published; 0 if not yet settled.
    function observation(uint256 policyId, uint8 phaseIndex)
        external
        view
        returns (uint32 observedMmX100, uint64 settledAt);
}
