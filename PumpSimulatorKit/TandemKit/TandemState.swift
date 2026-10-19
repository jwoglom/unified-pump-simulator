import Foundation

/// What the Tandem tab persists: where faketandem is, and when the tab was first started. The pump's
/// own state lives in faketandem.
class TandemState {
    /// The same variables TandemKit's integration harness reads, so one shell setup serves both.
    static let gattEnvironmentVariable = "FAKETANDEM_GATT"
    static let apiEnvironmentVariable = "FAKETANDEM_API_URL"

    init(rawValue: StateRawValue) {
        let environment = ProcessInfo.processInfo.environment
        gattEndpoint = environment[Self.gattEnvironmentVariable]
            ?? rawValue["gattEndpoint"] as? String
            ?? VirtualGattEndpoint.default.description
        apiURL = environment[Self.apiEnvironmentVariable]
            ?? rawValue["apiURL"] as? String
            ?? FaketandemClient.defaultBaseURL.absoluteString
        activatedAt = rawValue["activatedAt"] as? Date
    }

    func getRaw() -> StateRawValue {
        var state: StateRawValue = [:]
        state["gattEndpoint"] = gattEndpoint
        state["apiURL"] = apiURL
        state["activatedAt"] = activatedAt
        return state
    }

    /// `host:port` of faketandem's virtual GATT link (`-virtual-addr`).
    var gattEndpoint: String
    /// Base URL of faketandem's HTTP API (`-api-addr`).
    var apiURL: String
    var activatedAt: Date?
}
