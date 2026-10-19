import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// faketandem's HTTP API (its README, "Integration harness API"): what the simulator's panel reads
/// and the pump-side actions it offers. Every call is synchronous and bounded by `timeout`, so
/// callers stay off the main thread.
final class FaketandemClient {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:8080")!

    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, timeout: TimeInterval = 2) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration)
    }

    func snapshot() throws -> FaketandemSnapshot {
        try decode(send("GET", "/api/state"))
    }

    func pairingState() throws -> String {
        struct Body: Decodable {
            let pairingState: String
        }
        return try (decode(send("GET", "/api/bluetooth/pairingstate")) as Body).pairingState
    }

    /// `NotDiscoverable`, `DiscoverableOnly`, `PairStep1` or `PairStep2`.
    func setPairingState(_ state: String) throws {
        _ = try send("POST", "/api/bluetooth/pairingstate", json: ["pairingState": state])
    }

    /// Stages pump state fields (`PUT /api/state`), raising no qualifying events.
    func updateState(_ fields: [String: Any]) throws {
        _ = try send("PUT", "/api/state", json: fields)
    }

    /// A pump-side action (`POST /api/state/<path>`): `bolus/start`, `tempbasal/stop`, `suspend`, ...
    func action(_ path: String, _ body: [String: Any] = [:]) throws {
        _ = try send("POST", "/api/state/\(path)", json: body)
    }

    /// The ATT MTU faketandem fragments its notifications to (23...517).
    func setATTMTU(_ mtu: Int) throws {
        _ = try send("PUT", "/api/transport", json: ["att_mtu": mtu])
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw FaketandemClientError.decoding("\(error)")
        }
    }

    private func send(_ method: String, _ path: String, json: [String: Any]? = nil) throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw FaketandemClientError.transport("bad path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let done = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                outcome.result = .failure(FaketandemClientError.transport(error.localizedDescription))
            } else {
                outcome.result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            done.signal()
        }
        task.resume()
        done.wait()

        let (data, status) = try outcome.result.get()
        guard (200 ..< 300).contains(status) else {
            throw FaketandemClientError.http(status: status, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }
}

private final class Outcome {
    var result: Result<(Data, Int), Error> = .failure(FaketandemClientError.transport("no response"))
}

enum FaketandemClientError: Error, CustomStringConvertible {
    case transport(String)
    case http(status: Int, body: String)
    case decoding(String)

    var description: String {
        switch self {
        case let .transport(reason): return reason
        case let .http(status, body): return "HTTP \(status): \(body)"
        case let .decoding(reason): return "unexpected response: \(reason)"
        }
    }
}

/// The part of `GET /api/state` the panel shows.
struct FaketandemSnapshot: Decodable, Equatable {
    struct Identity: Decodable, Equatable {
        let serialNumber: String
        let model: String
        let firmwareVersion: String
        let apiVersionMajor: Int
        let apiVersionMinor: Int
    }

    struct Auth: Decodable, Equatable {
        let authenticated: Bool
        let pairingCode: String
        let longTermKeyPresent: Bool
        let pairingState: String
    }

    struct Connection: Decodable, Equatable {
        let connected: Bool
        let radioEnabled: Bool
    }

    struct Basal: Decodable, Equatable {
        let profileRate: Double
        let currentRate: Double
        let suspended: Bool
        let suspendReason: String?
        let tempActive: Bool
        let tempRate: Double
        let tempPercent: Int
        let tempStart: String?
        let tempEnd: String?
    }

    struct Bolus: Decodable, Equatable {
        let active: Bool
        let stalled: Bool
        let bolusId: Int
        let unitsTotal: Double
        let unitsDelivered: Double
        let sourceId: Int
    }

    struct Insulin: Decodable, Equatable {
        let reservoirUnits: Double
        let reservoirMax: Double
        let iob: Double
    }

    struct Battery: Decodable, Equatable {
        let percentage: Int
        let charging: Bool
    }

    struct Alert: Decodable, Equatable {
        let id: Int
        let type: Int
        let typeName: String
        let message: String
        let acknowledged: Bool
    }

    struct ControlIQ: Decodable, Equatable {
        let closedLoopEnabled: Bool
    }

    /// An insulin delivery profile, in the units the wire carries.
    struct IDPProfile: Codable, Equatable {
        struct Segment: Codable, Equatable {
            /// Minutes after midnight, pump local time.
            var startTime: Int
            /// Milliunits per hour.
            var basalRate: Int
            var carbRatio: Int
            var targetBg: Int
            var isf: Int
        }

        var id: Int
        var name: String
        var insulinDuration: Int
        var maxBolus: Int
        var carbEntry: Bool
        var segments: [Segment]
    }

    let identity: Identity
    let auth: Auth
    let connection: Connection
    let basal: Basal
    let bolus: Bolus
    let insulin: Insulin
    let battery: Battery
    let alerts: [Alert]
    let controlIq: ControlIQ
    let workflowMode: String
    let idpProfiles: [IDPProfile]

    /// Slot 0 is the active profile.
    var activeProfile: IDPProfile? {
        idpProfiles.first
    }

    /// RFC 3339 as faketandem writes it (nanosecond fractions, UTC), which `ISO8601DateFormatter`
    /// reads only with the fraction cut to milliseconds.
    static func date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else {
            return nil
        }
        var trimmed = string
        if let dot = string.firstIndex(of: "."),
           let end = string[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
        {
            let fraction = string[string.index(after: dot) ..< end].prefix(3)
            trimmed = String(string[..<dot]) + (fraction.isEmpty ? "" : "." + fraction) + String(string[end...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = trimmed.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}
