// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title Pool
/// @notice Underwriting capital. LPs deposit stablecoins and receive shares;
///         premiums flow in and payouts flow out, so share value tracks the
///         book's performance.
/// @dev The solvency rule is the point of this contract being onchain: total
///      reserved exposure can never exceed capital * solvencyRatio, and anyone
///      can read both numbers. An opaque insurer can be quietly insolvent; this
///      one cannot.
contract Pool {
    // ---------------------------------------------------------------- errors

    error NotAuthorised();
    error ZeroAmount();
    error InsufficientShares(uint256 held, uint256 requested);
    error WouldBreachSolvency(uint256 reserved, uint256 capacity);
    error InsufficientFreeCapital(uint256 free, uint256 requested);
    error NotReserved(uint256 reserved, uint256 requested);
    error InvalidRatio(uint16 ratioBps);
    error TransferFailed();

    // ---------------------------------------------------------------- events

    event Deposited(address indexed lp, uint256 assets, uint256 shares);
    event Withdrawn(address indexed lp, uint256 assets, uint256 shares);
    event PremiumReceived(address indexed from, uint256 amount);
    event ExposureReserved(address indexed by, uint256 amount, uint256 totalReserved);
    event ExposureReleased(address indexed by, uint256 amount, uint256 totalReserved);
    event PayoutSent(address indexed to, uint256 amount);
    event UnderwriterSet(address indexed underwriter, bool allowed);
    event SolvencyRatioSet(uint16 ratioBps);

    // ----------------------------------------------------------------- state

    uint256 internal constant BPS = 10_000;

    IERC20 public immutable asset;
    address public immutable governor;

    /// @notice Contracts permitted to reserve exposure and draw payouts.
    mapping(address => bool) public isUnderwriter;

    /// @notice Sum of max payouts across all active policies.
    uint256 public totalReserved;

    /// @notice Max exposure as a multiple of capital, in bps. 10_000 = fully
    ///         collateralised. Below 10_000 holds a buffer; above would be
    ///         fractional reserve, which defeats the transparency story.
    uint16 public solvencyRatioBps;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    // ------------------------------------------------------------- modifiers

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotAuthorised();
        _;
    }

    modifier onlyUnderwriter() {
        if (!isUnderwriter[msg.sender]) revert NotAuthorised();
        _;
    }

    constructor(IERC20 asset_, address governor_, uint16 solvencyRatioBps_) {
        if (solvencyRatioBps_ == 0 || solvencyRatioBps_ > BPS) {
            revert InvalidRatio(solvencyRatioBps_);
        }
        asset = asset_;
        governor = governor_;
        solvencyRatioBps = solvencyRatioBps_;
    }

    // ------------------------------------------------------------ accounting

    /// @notice Stablecoins held by the pool.
    /// @dev Balance-based rather than a running total, so a direct transfer in
    ///      (a donation, or a premium paid out of band) counts as capital
    ///      rather than being stranded.
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Capital not backing an active policy.
    function freeCapital() public view returns (uint256) {
        uint256 assets = totalAssets();
        return assets > totalReserved ? assets - totalReserved : 0;
    }

    /// @notice Maximum exposure the pool may carry at current capital.
    function capacity() public view returns (uint256) {
        return (totalAssets() * solvencyRatioBps) / BPS;
    }

    /// @notice Exposure that can still be written.
    function availableCapacity() public view returns (uint256) {
        uint256 cap = capacity();
        return cap > totalReserved ? cap - totalReserved : 0;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalShares;
        if (supply == 0) return assets;
        return (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalShares;
        if (supply == 0) return shares;
        return (shares * totalAssets()) / supply;
    }

    // ----------------------------------------------------------------- LP io

    /// @notice Deposit stablecoins and mint shares.
    function deposit(uint256 assets) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();

        // Share price must be computed against capital *before* this deposit
        // lands, otherwise the depositor dilutes themselves.
        shares = convertToShares(assets);
        if (shares == 0) revert ZeroAmount();

        totalShares += shares;
        sharesOf[msg.sender] += shares;

        // Emit before the external call: a reentrant token could otherwise
        // interleave logs, and the LP dashboard reads these events as the
        // record of what happened.
        emit Deposited(msg.sender, assets, shares);
        _pull(msg.sender, assets);
    }

    /// @notice Burn shares and withdraw stablecoins.
    /// @dev Only free capital is withdrawable. Capital backing an active policy
    ///      is locked until the policy settles — that is what makes the cover
    ///      real rather than a promise.
    function withdraw(uint256 shares) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        uint256 held = sharesOf[msg.sender];
        if (held < shares) revert InsufficientShares(held, shares);

        assets = convertToAssets(shares);
        uint256 free = freeCapital();
        if (assets > free) revert InsufficientFreeCapital(free, assets);

        sharesOf[msg.sender] = held - shares;
        totalShares -= shares;

        emit Withdrawn(msg.sender, assets, shares);
        _push(msg.sender, assets);
    }

    // ------------------------------------------------------- underwriting io

    /// @notice Reserve capital against a newly written policy.
    function reserve(uint256 amount) external onlyUnderwriter {
        if (amount == 0) revert ZeroAmount();

        uint256 newReserved = totalReserved + amount;
        uint256 cap = capacity();
        if (newReserved > cap) revert WouldBreachSolvency(newReserved, cap);

        totalReserved = newReserved;
        emit ExposureReserved(msg.sender, amount, newReserved);
    }

    /// @notice Release reserved capital once a policy's exposure has resolved.
    function release(uint256 amount) external onlyUnderwriter {
        if (amount == 0) revert ZeroAmount();
        if (amount > totalReserved) revert NotReserved(totalReserved, amount);

        unchecked {
            totalReserved -= amount;
        }
        emit ExposureReleased(msg.sender, amount, totalReserved);
    }

    /// @notice Collect a premium into pool capital.
    function collectPremium(address from, uint256 amount) external onlyUnderwriter {
        if (amount == 0) revert ZeroAmount();
        emit PremiumReceived(from, amount);
        _pull(from, amount);
    }

    /// @notice Pay a settled claim.
    /// @dev The caller is responsible for releasing the matching reservation.
    function payout(address to, uint256 amount) external onlyUnderwriter {
        if (amount == 0) revert ZeroAmount();
        emit PayoutSent(to, amount);
        _push(to, amount);
    }

    // ------------------------------------------------------------ governance

    function setUnderwriter(address underwriter, bool allowed) external onlyGovernor {
        isUnderwriter[underwriter] = allowed;
        emit UnderwriterSet(underwriter, allowed);
    }

    /// @notice Adjust the solvency ratio.
    /// @dev Cannot be raised above full collateralisation, and cannot be cut so
    ///      far that already-written policies become unbacked.
    function setSolvencyRatio(uint16 ratioBps) external onlyGovernor {
        if (ratioBps == 0 || ratioBps > BPS) revert InvalidRatio(ratioBps);

        uint256 newCapacity = (totalAssets() * ratioBps) / BPS;
        if (totalReserved > newCapacity) {
            revert WouldBreachSolvency(totalReserved, newCapacity);
        }

        solvencyRatioBps = ratioBps;
        emit SolvencyRatioSet(ratioBps);
    }

    // --------------------------------------------------------------- erc20io

    function _pull(address from, uint256 amount) internal {
        if (!asset.transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _push(address to, uint256 amount) internal {
        if (!asset.transfer(to, amount)) revert TransferFailed();
    }
}
