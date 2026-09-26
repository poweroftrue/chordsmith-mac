import Darwin

/// Puts CGEvent and IOHID timestamps on one clock: nanoseconds of system
/// uptime (`CLOCK_UPTIME_RAW`).
///
/// IOHID values are stamped in mach absolute ticks. CGEvent documents its
/// timestamp as nanoseconds, but keyboard events read at the HID event tap on
/// Apple silicon carry raw mach ticks (1 tick = 125/3 ns), while other events
/// carry nanoseconds. Comparing the two without normalizing puts M4G key
/// reports days away from their keyboard events, so none ever matched.
public enum EventClock {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// Accept a unit interpretation only if it lands this close to "now".
    static let plausibilityWindowNanoseconds: UInt64 = 10_000_000_000

    public static func nowUptimeNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    public static func nanoseconds(fromMachTicks ticks: UInt64) -> UInt64 {
        nanoseconds(fromMachTicks: ticks, numer: timebase.numer, denom: timebase.denom)
    }

    static func nanoseconds(fromMachTicks ticks: UInt64, numer: UInt64, denom: UInt64) -> UInt64 {
        (ticks / denom) * numer + ((ticks % denom) * numer) / denom
    }

    /// Returns the event time in uptime nanoseconds, whichever unit the raw
    /// CGEvent timestamp used. Falls back to `now` for synthetic events
    /// (timestamp 0) or values that fit neither unit.
    public static func uptimeNanoseconds(forEventTimestamp raw: UInt64) -> UInt64 {
        uptimeNanoseconds(
            forEventTimestamp: raw,
            now: nowUptimeNanoseconds(),
            numer: timebase.numer,
            denom: timebase.denom
        )
    }

    static func uptimeNanoseconds(
        forEventTimestamp raw: UInt64,
        now: UInt64,
        numer: UInt64,
        denom: UInt64
    ) -> UInt64 {
        guard raw > 0 else { return now }
        let asTicks = nanoseconds(fromMachTicks: raw, numer: numer, denom: denom)
        let best = distance(raw, now) <= distance(asTicks, now) ? raw : asTicks
        return distance(best, now) <= plausibilityWindowNanoseconds ? best : now
    }

    private static func distance(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }
}
