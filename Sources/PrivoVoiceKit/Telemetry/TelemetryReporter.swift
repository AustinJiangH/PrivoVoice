// The only part of PrivoVoice that ever touches the network — and it is opt-in,
// off by default, and utterly non-essential.
//
// Design contract (see the Dashboard toggle disclosure):
//   • It sends AGGREGATE COUNTS + DEVICE METADATA only. Never transcript text,
//     never audio, never anything the user typed or said.
//   • It is FIRE-AND-FORGET and FAIL-SILENT. Offline, DNS failure, timeout, a
//     500 from the server, opted-out — every path is a silent no-op. Nothing
//     here can throw into, block, or slow down the dictation pipeline.

import Foundation

/// One usage report. Encodes to the JSON body of a POST. Deliberately contains
/// no free-form user content — only numbers and coarse device/build metadata.
public struct TelemetryEvent: Codable, Sendable, Equatable {
    /// Anonymous, random per-install identifier (for de-duping installs).
    public var installID: String
    /// e.g. "PrivoVoice 0.1.0".
    public var appVersion: String
    /// e.g. "Version 15.0 (Build 24A335)".
    public var osVersion: String
    /// Catalog id of the model in use, if any (e.g. "parakeet-tdt-0.6b-v2").
    public var modelID: String?
    /// This single dictation's measured audio length, in seconds.
    public var sessionSeconds: Double
    /// This single dictation's word count.
    public var sessionWords: Int
    /// Lifetime local totals at the time of this event.
    public var totalSeconds: Double
    public var totalWords: Int
    public var totalSessions: Int

    public init(
        installID: String, appVersion: String, osVersion: String, modelID: String?,
        sessionSeconds: Double, sessionWords: Int,
        totalSeconds: Double, totalWords: Int, totalSessions: Int
    ) {
        self.installID = installID
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.modelID = modelID
        self.sessionSeconds = sessionSeconds
        self.sessionWords = sessionWords
        self.totalSeconds = totalSeconds
        self.totalWords = totalWords
        self.totalSessions = totalSessions
    }
}

/// Emits `TelemetryEvent`s. Abstracted so `Telemetry` can be handed a test
/// double, and so a future backend (a different transport, a batching queue)
/// drops in without touching the recording path.
public protocol TelemetryReporting: Sendable {
    func send(_ event: TelemetryEvent)
}

/// Posts `TelemetryEvent`s to a collector. Value type; cheap to copy.
public struct TelemetryReporter: TelemetryReporting, Sendable {
    /// Default collector endpoint. Overridable for self-hosting or tests.
    public static let defaultEndpoint = URL(string: "https://telemetry.privovoice.app/v1/usage")!

    let endpoint: URL
    let session: URLSession

    public init(endpoint: URL = TelemetryReporter.defaultEndpoint,
                session: URLSession = .privoTelemetry) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Post one event. Returns immediately; the request runs detached at
    /// background priority and any and every error is swallowed. Calling this
    /// can never affect the caller — that's the whole point.
    public func send(_ event: TelemetryEvent) {
        guard let body = try? JSONEncoder().encode(event) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let session = self.session
        Task.detached(priority: .background) {
            // Intentionally ignored: telemetry must never surface a failure.
            _ = try? await session.data(for: request)
        }
    }
}

public extension URLSession {
    /// Short timeouts and NO connectivity waiting, so an offline device fails
    /// fast and silently instead of queuing requests. Ephemeral: nothing about
    /// telemetry is persisted to a cache or cookie store.
    static let privoTelemetry: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()
}
