// Pure recording-timeline math for the HUD lens — no SwiftUI, so it's portable
// (a future iOS HUD reuses it) and unit-testable. The view maps `status` to a
// color and draws the ring; all the arithmetic lives here.

import Foundation

public struct RecordingProgress: Equatable, Sendable {
    /// Where we are relative to the model's single-pass limit.
    public enum Status: Equatable, Sendable {
        /// Unbounded streaming model — count up, no limit.
        case streaming
        /// Comfortably within the window.
        case normal
        /// Under 10s of headroom — the red-warning window.
        case warning
        /// Past the window; recording continues and the audio gets segmented.
        case over
    }

    public let elapsed: Double
    public let limit: Double?

    public init(elapsed: Double, limit: Double?) {
        self.elapsed = max(0, elapsed)
        self.limit = limit
    }

    /// Derive from the recording start and the current instant.
    public init(start: Date?, limit: Double?, now: Date) {
        self.init(elapsed: start.map { max(0, now.timeIntervalSince($0)) } ?? 0, limit: limit)
    }

    public var isUnbounded: Bool { limit == nil }
    /// Seconds until the limit; negative once past it. `nil` when unbounded.
    public var remaining: Double? { limit.map { $0 - elapsed } }

    public var status: Status {
        guard let remaining else { return .streaming }
        if remaining < 0 { return .over }
        if remaining <= 10 { return .warning }
        return .normal
    }

    /// Ring fill, growing from empty (0) toward full (1) as elapsed approaches
    /// the limit. 0 for streaming (the ring spins indeterminately instead).
    public var fraction: Double {
        guard let limit, limit > 0 else { return 0 }
        return max(0, min(1, elapsed / limit))
    }

    /// The big number inside the lens: how long we've been recording (count-up).
    /// We show elapsed time, not a countdown — the ring/color carry the limit.
    public var centerText: String {
        Self.mmss(elapsed)
    }

    /// The minute just crossed, while within a short flash window after it — so
    /// the HUD can pop a "1 min" / "2 min" reminder. `nil` otherwise.
    public var milestoneMinute: Int? {
        guard elapsed >= 60, elapsed.truncatingRemainder(dividingBy: 60) < 2.5 else { return nil }
        return Int(elapsed / 60)
    }

    /// The transient message beside the lens (approaching/over the limit, or a
    /// minute reminder), or `nil` when there's nothing to say. No countdown — we
    /// just flag the limit, we don't tick down to it.
    public var secondaryText: String? {
        switch status {
        case .over: return "over limit · will segment"
        case .warning: return "near limit"
        case .normal, .streaming:
            return milestoneMinute.map { "\($0) min" }
        }
    }

    /// `m:ss`.
    public static func mmss(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
