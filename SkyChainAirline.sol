// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SkyMiles} from "./SkyMiles.sol";
import {FlightTicket} from "./FlightTicket.sol";

/// @title SkyChainAirline — on-chain booking, escrow, refunds and loyalty
/// @notice Life of a ticket:
///   1. The airline publishes a flight (AIRLINE_ROLE).
///   2. A passenger books with ETH (held in escrow) or with SkyMiles (burned)
///      and receives a FlightTicket NFT. The NFT can be resold until check-in.
///   3. The passenger can cancel; the refund depends on how early they cancel.
///   4. Check-in opens 48h before departure and locks the NFT (boarding pass).
///   5. A flight-status oracle (ORACLE_ROLE) reports delays, departure, landing.
///   6. Delays of 3h+ pay automatic compensation from the airline's bonded
///      compensation pool (parametric, no claim form, no paperwork).
///   7. If the airline cancels, every ticket holder gets a full refund plus
///      a cancellation compensation.
///   8. After landing, passengers who flew claim their miles and the airline
///      settles the flight to move the escrow to its treasury.
/// @dev Security patterns: role-based access control, checks-effects-interactions,
///      reentrancy guard, pull payments (no ETH is pushed to arbitrary addresses
///      inside business logic), pausable circuit breaker, custom errors.
contract SkyChainAirline is AccessControl, Pausable, ReentrancyGuard {
    // ============================================================ roles

    bytes32 public constant AIRLINE_ROLE = keccak256("AIRLINE_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ============================================================ policy

    uint256 public constant BPS = 10_000;
    uint256 public constant FULL_REFUND_WINDOW = 7 days;    // cancel ≥ 7 days out  → 100 %
    uint256 public constant PARTIAL_REFUND_WINDOW = 48 hours; // cancel ≥ 48 h out    → 50 %
    uint256 public constant PARTIAL_REFUND_BPS = 5_000;       // otherwise             → 0 %
    uint256 public constant CHECKIN_OPENS = 48 hours;
    uint256 public constant CHECKIN_CLOSES = 1 hours;
    uint32 public constant DELAY_THRESHOLD_MINUTES = 180;
    uint256 public constant DELAY_COMPENSATION_BPS = 5_000;        // 50 % of fare
    uint256 public constant CANCELLATION_COMPENSATION_BPS = 2_500; // 25 % of fare

    // ============================================================ types

    enum FlightStatus { None, Scheduled, Delayed, Cancelled, Departed, Landed }

    struct Flight {
        string code;
        string origin;
        string destination;
        uint64 departure;     // scheduled departure (unix seconds)
        uint32 capacity;
        uint32 sold;
        uint32 nextSeat;
        uint32 delayMinutes;
        FlightStatus status;
        bool settled;
        uint128 price;        // fare in wei
        uint128 milesPrice;   // award fare in MILES (0 = no award seats)
        uint128 milesReward;  // miles earned by flying
        uint128 escrow;       // refundable passenger ETH still held for this flight
    }

    struct Booking {
        uint256 flightId;
        uint128 paidWei;
        uint128 paidMiles;
        bool checkedIn;
        bool compensated;
        bool milesClaimed;
    }

    // ============================================================ storage

    SkyMiles public immutable miles;
    FlightTicket public immutable tickets;

    address public treasury;
    uint256 public compensationPool;
    uint256 public flightCount;

    mapping(uint256 => Flight) private _flights;           // flightId => Flight
    mapping(uint256 => Booking) private _bookings;         // ticketId => Booking
    mapping(address => uint256) public pendingWithdrawals; // pull-payment ledger

    // ============================================================ events

    event FlightCreated(uint256 indexed flightId, string code, string origin, string destination, uint64 departure, uint32 capacity, uint128 price, uint128 milesPrice);
    event TicketBooked(uint256 indexed ticketId, uint256 indexed flightId, address indexed passenger, uint32 seat, uint128 paidWei, uint128 paidMiles);
    event BookingCancelled(uint256 indexed ticketId, address indexed passenger, uint256 refundWei, uint256 refundMiles, uint256 penaltyWei);
    event CheckedIn(uint256 indexed ticketId, address indexed passenger);
    event FlightDelayed(uint256 indexed flightId, uint32 delayMinutes);
    event FlightCancelled(uint256 indexed flightId);
    event FlightDeparted(uint256 indexed flightId);
    event FlightLanded(uint256 indexed flightId);
    event FlightSettled(uint256 indexed flightId, uint256 revenue);
    event CancellationRefunded(uint256 indexed ticketId, address indexed passenger, uint256 refundWei, uint256 refundMiles, uint256 compensationWei);
    event DelayCompensated(uint256 indexed ticketId, address indexed passenger, uint256 compensationWei, uint256 bonusMiles);
    event MilesClaimed(uint256 indexed ticketId, address indexed passenger, uint256 amount);
    event PoolFunded(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event TreasuryUpdated(address indexed treasury);

    // ============================================================ errors

    error InvalidFlight();
    error InvalidParameters();
    error WrongStatus(FlightStatus current);
    error BookingClosed();
    error SoldOut();
    error WrongPayment(uint256 expected, uint256 received);
    error AwardSeatsUnavailable();
    error NotTicketOwner();
    error AlreadyCheckedIn();
    error CheckInNotOpen();
    error NotEligible();
    error AlreadyClaimed();
    error InsufficientPool(uint256 needed, uint256 available);
    error NothingToWithdraw();
    error TransferFailed();

    // ============================================================ constructor

    constructor(address admin, address treasury_, SkyMiles miles_, FlightTicket tickets_) {
        if (admin == address(0) || treasury_ == address(0)) revert InvalidParameters();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AIRLINE_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        treasury = treasury_;
        miles = miles_;
        tickets = tickets_;
    }

    // ============================================================ modifiers

    modifier onlyTicketOwner(uint256 ticketId) {
        if (tickets.ownerOf(ticketId) != msg.sender) revert NotTicketOwner();
        _;
    }

    modifier flightExists(uint256 flightId) {
        if (_flights[flightId].status == FlightStatus.None) revert InvalidFlight();
        _;
    }

    // ============================================================ airline

    function createFlight(
        string calldata code,
        string calldata origin,
        string calldata destination,
        uint64 departure,
        uint32 capacity,
        uint128 price,
        uint128 milesPrice,
        uint128 milesReward
    ) external onlyRole(AIRLINE_ROLE) returns (uint256 flightId) {
        if (capacity == 0 || price == 0 || departure <= block.timestamp + CHECKIN_OPENS) revert InvalidParameters();

        flightId = ++flightCount;
        Flight storage f = _flights[flightId];
        f.code = code;
        f.origin = origin;
        f.destination = destination;
        f.departure = departure;
        f.capacity = capacity;
        f.price = price;
        f.milesPrice = milesPrice;
        f.milesReward = milesReward;
        f.status = FlightStatus.Scheduled;

        emit FlightCreated(flightId, code, origin, destination, departure, capacity, price, milesPrice);
    }

    function cancelFlight(uint256 flightId) external onlyRole(AIRLINE_ROLE) flightExists(flightId) {
        Flight storage f = _flights[flightId];
        if (f.status != FlightStatus.Scheduled && f.status != FlightStatus.Delayed) revert WrongStatus(f.status);
        f.status = FlightStatus.Cancelled;
        emit FlightCancelled(flightId);
    }

    /// @notice Moves a landed flight's escrow (fares of everyone who did not
    ///         cancel, including no-shows) to the airline treasury.
    function settleFlight(uint256 flightId) external onlyRole(AIRLINE_ROLE) flightExists(flightId) {
        Flight storage f = _flights[flightId];
        if (f.status != FlightStatus.Landed) revert WrongStatus(f.status);
        if (f.settled) revert AlreadyClaimed();
        uint256 revenue = f.escrow;
        f.settled = true;
        f.escrow = 0;
        pendingWithdrawals[treasury] += revenue;
        emit FlightSettled(flightId, revenue);
    }

    /// @notice Anyone may top up the bond, but it is meant for the airline.
    function fundCompensationPool() external payable {
        if (msg.value == 0) revert InvalidParameters();
        compensationPool += msg.value;
        emit PoolFunded(msg.sender, msg.value);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidParameters();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ============================================================ oracle

    /// @param totalDelayMinutes cumulative delay versus the scheduled time (can only grow)
    function reportDelay(uint256 flightId, uint32 totalDelayMinutes) external onlyRole(ORACLE_ROLE) flightExists(flightId) {
        Flight storage f = _flights[flightId];
        if (f.status != FlightStatus.Scheduled && f.status != FlightStatus.Delayed) revert WrongStatus(f.status);
        if (totalDelayMinutes <= f.delayMinutes) revert InvalidParameters();
        f.delayMinutes = totalDelayMinutes;
        f.status = FlightStatus.Delayed;
        emit FlightDelayed(flightId, totalDelayMinutes);
    }

    function reportDeparture(uint256 flightId) external onlyRole(ORACLE_ROLE) flightExists(flightId) {
        Flight storage f = _flights[flightId];
        if (f.status != FlightStatus.Scheduled && f.status != FlightStatus.Delayed) revert WrongStatus(f.status);
        f.status = FlightStatus.Departed;
        emit FlightDeparted(flightId);
    }

    function reportLanding(uint256 flightId) external onlyRole(ORACLE_ROLE) flightExists(flightId) {
        Flight storage f = _flights[flightId];
        if (f.status != FlightStatus.Departed) revert WrongStatus(f.status);
        f.status = FlightStatus.Landed;
        emit FlightLanded(flightId);
    }

    // ============================================================ passenger: booking

    function bookFlight(uint256 flightId) external payable whenNotPaused nonReentrant returns (uint256 ticketId) {
        Flight storage f = _openForBooking(flightId);
        if (msg.value != f.price) revert WrongPayment(f.price, msg.value);

        f.escrow += uint128(msg.value);
        ticketId = _issueTicket(flightId, f, uint128(msg.value), 0);
    }

    /// @notice Award booking. Requires a prior `miles.approve(address(this), milesPrice)`
    ///         (or an EIP-2612 permit) because miles are burned with burnFrom.
    function bookWithMiles(uint256 flightId) external whenNotPaused nonReentrant returns (uint256 ticketId) {
        Flight storage f = _openForBooking(flightId);
        if (f.milesPrice == 0) revert AwardSeatsUnavailable();

        miles.burnFrom(msg.sender, f.milesPrice);
        ticketId = _issueTicket(flightId, f, 0, f.milesPrice);
    }

    function cancelBooking(uint256 ticketId) external nonReentrant onlyTicketOwner(ticketId) {
        Booking memory b = _bookings[ticketId];
        Flight storage f = _flights[b.flightId];
        if (f.status != FlightStatus.Scheduled && f.status != FlightStatus.Delayed) revert WrongStatus(f.status);
        if (b.checkedIn) revert AlreadyCheckedIn();

        uint256 refundBps = _refundBps(f);
        uint256 refundWei = (uint256(b.paidWei) * refundBps) / BPS;
        uint256 penaltyWei = uint256(b.paidWei) - refundWei;
        uint256 refundMiles = (uint256(b.paidMiles) * refundBps) / BPS;

        // effects
        f.escrow -= b.paidWei;
        f.sold -= 1;
        delete _bookings[ticketId];
        pendingWithdrawals[msg.sender] += refundWei;
        pendingWithdrawals[treasury] += penaltyWei;

        // interactions (trusted contracts only)
        tickets.burn(ticketId);
        if (refundMiles > 0) miles.mint(msg.sender, refundMiles, "REFUND");

        emit BookingCancelled(ticketId, msg.sender, refundWei, refundMiles, penaltyWei);
    }

    function checkIn(uint256 ticketId) external whenNotPaused onlyTicketOwner(ticketId) {
        Booking storage b = _bookings[ticketId];
        Flight storage f = _flights[b.flightId];
        if (f.status != FlightStatus.Scheduled && f.status != FlightStatus.Delayed) revert WrongStatus(f.status);
        if (b.checkedIn) revert AlreadyCheckedIn();

        uint256 dep = effectiveDeparture(b.flightId);
        if (block.timestamp + CHECKIN_OPENS < dep || block.timestamp + CHECKIN_CLOSES > dep) revert CheckInNotOpen();

        b.checkedIn = true;
        tickets.lock(ticketId);
        emit CheckedIn(ticketId, msg.sender);
    }

    // ============================================================ passenger: claims

    /// @notice Full refund (cash or miles) plus 25 % of the fare when the airline cancels.
    function claimCancellationRefund(uint256 ticketId) external nonReentrant onlyTicketOwner(ticketId) {
        Booking memory b = _bookings[ticketId];
        Flight storage f = _flights[b.flightId];
        if (f.status != FlightStatus.Cancelled) revert WrongStatus(f.status);

        uint256 compensation = (uint256(f.price) * CANCELLATION_COMPENSATION_BPS) / BPS;
        if (compensationPool < compensation) revert InsufficientPool(compensation, compensationPool);

        compensationPool -= compensation;
        f.escrow -= b.paidWei;
        delete _bookings[ticketId];
        pendingWithdrawals[msg.sender] += uint256(b.paidWei) + compensation;

        tickets.burn(ticketId);
        if (b.paidMiles > 0) miles.mint(msg.sender, b.paidMiles, "REFUND");

        emit CancellationRefunded(ticketId, msg.sender, b.paidWei, b.paidMiles, compensation);
    }

    /// @notice Parametric delay insurance: 50 % of the fare + double miles for
    ///         checked-in passengers when the oracle reported a 3h+ delay.
    function claimDelayCompensation(uint256 ticketId) external nonReentrant onlyTicketOwner(ticketId) {
        Booking storage b = _bookings[ticketId];
        Flight storage f = _flights[b.flightId];
        if (f.status != FlightStatus.Departed && f.status != FlightStatus.Landed) revert WrongStatus(f.status);
        if (!b.checkedIn || f.delayMinutes < DELAY_THRESHOLD_MINUTES) revert NotEligible();
        if (b.compensated) revert AlreadyClaimed();

        uint256 compensation = (uint256(f.price) * DELAY_COMPENSATION_BPS) / BPS;
        if (compensationPool < compensation) revert InsufficientPool(compensation, compensationPool);

        b.compensated = true;
        compensationPool -= compensation;
        pendingWithdrawals[msg.sender] += compensation;
        if (f.milesReward > 0) miles.mint(msg.sender, f.milesReward, "DELAY_BONUS");

        emit DelayCompensated(ticketId, msg.sender, compensation, f.milesReward);
    }

    function claimMiles(uint256 ticketId) external nonReentrant onlyTicketOwner(ticketId) {
        Booking storage b = _bookings[ticketId];
        Flight storage f = _flights[b.flightId];
        if (f.status != FlightStatus.Landed) revert WrongStatus(f.status);
        if (!b.checkedIn) revert NotEligible();
        if (b.milesClaimed) revert AlreadyClaimed();

        b.milesClaimed = true;
        miles.mint(msg.sender, f.milesReward, "FLIGHT");
        emit MilesClaimed(ticketId, msg.sender, f.milesReward);
    }

    /// @notice Pull-payment withdrawal for refunds, compensations and airline revenue.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    // ============================================================ views

    function getFlight(uint256 flightId) external view returns (Flight memory) {
        return _flights[flightId];
    }

    function getBooking(uint256 ticketId) external view returns (Booking memory) {
        return _bookings[ticketId];
    }

    function effectiveDeparture(uint256 flightId) public view returns (uint256) {
        Flight storage f = _flights[flightId];
        return uint256(f.departure) + uint256(f.delayMinutes) * 1 minutes;
    }

    /// @return refundBps share refunded if cancelled now, with the wei and miles amounts
    function refundQuote(uint256 ticketId) external view returns (uint256 refundBps, uint256 refundWei, uint256 refundMiles) {
        Booking memory b = _bookings[ticketId];
        refundBps = _refundBps(_flights[b.flightId]);
        refundWei = (uint256(b.paidWei) * refundBps) / BPS;
        refundMiles = (uint256(b.paidMiles) * refundBps) / BPS;
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ============================================================ internals

    function _openForBooking(uint256 flightId) private view returns (Flight storage f) {
        f = _flights[flightId];
        if (f.status == FlightStatus.None) revert InvalidFlight();
        if (f.status != FlightStatus.Scheduled && f.status != FlightStatus.Delayed) revert WrongStatus(f.status);
        if (block.timestamp + CHECKIN_CLOSES > effectiveDeparture(flightId)) revert BookingClosed();
        if (f.sold >= f.capacity) revert SoldOut();
    }

    function _issueTicket(uint256 flightId, Flight storage f, uint128 paidWei, uint128 paidMiles)
        private
        returns (uint256 ticketId)
    {
        f.sold += 1;
        uint32 seat = ++f.nextSeat;

        ticketId = tickets.issue(
            msg.sender,
            FlightTicket.TicketData({
                flightId: flightId,
                flightCode: f.code,
                origin: f.origin,
                destination: f.destination,
                departure: f.departure,
                seat: seat,
                awardTicket: paidMiles > 0
            })
        );
        _bookings[ticketId] = Booking({
            flightId: flightId,
            paidWei: paidWei,
            paidMiles: paidMiles,
            checkedIn: false,
            compensated: false,
            milesClaimed: false
        });

        emit TicketBooked(ticketId, flightId, msg.sender, seat, paidWei, paidMiles);
    }

    function _refundBps(Flight storage f) private view returns (uint256) {
        uint256 dep = uint256(f.departure) + uint256(f.delayMinutes) * 1 minutes;
        if (block.timestamp >= dep) return 0;
        uint256 timeLeft = dep - block.timestamp;
        if (timeLeft >= FULL_REFUND_WINDOW) return BPS;
        if (timeLeft >= PARTIAL_REFUND_WINDOW) return PARTIAL_REFUND_BPS;
        return 0;
    }

    /// @dev Plain ETH sent without calling a function is rejected; use bookFlight or fundCompensationPool.
    receive() external payable {
        revert InvalidParameters();
    }
}
