import Foundation
import SwiftUI
#if canImport(AppKit)
    import AppKit
#endif

/// The Tandem tab: a real Bluetooth front end for faketandem, the Tandem pump emulator TandemKit's
/// own integration tests run against. faketandem holds the pump, its protocol and its history; this
/// manager puts it on the air (`TandemBluetoothManager`) and shows and drives its state through its
/// HTTP API (`FaketandemClient`). At the default addresses it fetches faketandem's newest release
/// from GitHub (`FaketandemInstaller`) and runs it (`FaketandemProcess`) unless one already answers.
public class TandemPumpManager: PumpManagerProtocol {
    public static let identifier: String = "tandemkit"
    public var title: String = "TandemKit"

    public var capabilities = PumpManagerCapabitilties(
        supportedModels: [
            PumpModel(name: "Mobi", image: Image(imageName: "mobi"), index: 0),
        ],
        canExpire: false,
        actions: []
    )

    public var currentModel: PumpModel {
        get { capabilities.supportedModels[0] }
        set {}
    }

    public var expiresAt: Date? {
        nil
    }

    public var activatedAt: Date? {
        state.activatedAt
    }

    public var storageDelegate: (any StorageDelegate)?
    public var rawState: StateRawValue {
        state.getRaw()
    }

    public var pumpState: String {
        let (snapshot, _, status) = current()
        var parts: [String] = []
        switch status {
        case .stopped:
            parts.append("Stopped")
        case let .waitingForFaketandem(reason):
            parts.append("Waiting for faketandem: \(reason)")
        case .bluetoothUnavailable:
            parts.append("Bluetooth is not powered on")
        case let .advertising(name):
            parts.append("Advertising as \(name)")
        case let .centralConnected(name):
            parts.append("App connected to \(name)")
        case let .linkLost(reason):
            parts.append("faketandem dropped the link: \(reason)")
        }
        if let snapshot {
            parts.append(snapshot.auth.pairingState)
            if snapshot.auth.authenticated {
                parts.append("authenticated")
            } else if snapshot.auth.longTermKeyPresent {
                parts.append("paired")
            } else {
                parts.append("not paired")
            }
        }
        return parts.joined(separator: " - ")
    }

    public var pumpNotes: String {
        let (snapshot, error, _) = current()
        var lines = ["faketandem link \(state.gattEndpoint), API \(state.apiURL)"]
        if let snapshot {
            lines.append(
                "\(snapshot.identity.model) serial \(snapshot.identity.serialNumber), API \(snapshot.identity.apiVersionMajor).\(snapshot.identity.apiVersionMinor)"
            )
            lines.append("Pairing code \(snapshot.auth.pairingCode)")
            if snapshot.controlIq.closedLoopEnabled {
                lines.append("Control-IQ on")
            }
            if !snapshot.alerts.isEmpty {
                lines.append("Alerts: " + snapshot.alerts.map(\.typeName).joined(separator: ", "))
            }
        } else if let error {
            lines.append("faketandem's API is not reachable (\(error))")
            if installer == nil {
                lines.append("Start it from the faketandem repository: go run . -transport virtual -q")
            }
        }
        if let faketandemStatus = currentFaketandemStatus {
            lines.append(faketandemStatus)
        }
        lines.append(
            "Override with \(TandemState.gattEnvironmentVariable), \(TandemState.apiEnvironmentVariable) and \(FaketandemRelease.environmentVariable) in the app's environment"
        )
        return lines.joined(separator: "\n")
    }

    public var batteryLevel: String? {
        guard let battery = current().snapshot?.battery else {
            return nil
        }
        return "\(battery.percentage)%" + (battery.charging ? " (charging)" : "")
    }

    public var reservoirLevel: Double {
        current().snapshot?.insulin.reservoirUnits ?? 0
    }

    public var basalState: BasalState {
        let (snapshot, _, _) = current()
        guard let snapshot else {
            return .active(rate: 0)
        }
        if snapshot.basal.suspended {
            return .suspended(start: suspendedSince ?? Date(), duration: nil)
        }
        if snapshot.basal.tempActive,
           let start = FaketandemSnapshot.date(snapshot.basal.tempStart),
           let end = FaketandemSnapshot.date(snapshot.basal.tempEnd)
        {
            return .tempBasal(rate: snapshot.basal.tempRate, start: start, end: end)
        }
        return .active(rate: snapshot.basal.profileRate)
    }

    public var bolusProgress: BolusState? {
        guard let bolus = current().snapshot?.bolus, bolus.active else {
            return nil
        }
        return BolusState(total: bolus.unitsTotal, progress: bolus.unitsDelivered)
    }

    /// The active insulin delivery profile's basal segments. Setting it rewrites that profile's
    /// segments on faketandem, keeping its other fields.
    public var basal: [BasalItem] {
        get {
            guard let profile = current().snapshot?.activeProfile else {
                return []
            }
            return profile.segments.map {
                BasalItem(start: TimeInterval($0.startTime * 60), rate: Double($0.basalRate) / 1000)
            }
        }
        set {
            perform("basal profile") { client in
                let snapshot = try client.snapshot()
                guard var profile = snapshot.activeProfile, let template = profile.segments.first else {
                    throw FaketandemClientError.transport("faketandem holds no profile to write the schedule into")
                }
                profile.segments = newValue.map { item in
                    var segment = template
                    segment.startTime = Int(item.start / 60)
                    segment.basalRate = Int((item.rate * 1000).rounded())
                    return segment
                }
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                let profiles = [profile] + snapshot.idpProfiles.dropFirst()
                let json = try JSONSerialization.jsonObject(with: encoder.encode(profiles))
                try client.updateState(["idp_profiles": json])
            }
        }
    }

    private let logger = PumpManagerLogger(subsystem: "com.bastiaanv.tandemkit", category: "TandemPumpManager")
    private let bluetooth: TandemBluetoothManager
    private let workQueue = DispatchQueue(label: "com.bastiaanv.tandemkit.faketandem")
    private let lock = NSLock()
    private var state: TandemState
    private var client: FaketandemClient
    private var snapshot: FaketandemSnapshot?
    private var snapshotError: String?
    private var suspendedSince: Date?
    private var bridgeStatus: TandemBluetoothManager.Status = .stopped
    private var pollTimer: DispatchSourceTimer?
    private var isRunning = false

    /// nil when faketandem is the developer's to start: another address, or `FAKETANDEM_RELEASE=none`.
    private let installer: FaketandemInstaller?
    /// The faketandem the tab started. All on `workQueue`, as is the status.
    private var faketandem: FaketandemProcess?
    private var faketandemStatus: String?
    private var lastLaunch: Date?
    private var exitsInARow = 0
    private static let launchRetryInterval: TimeInterval = 10
    private static let launchExitLimit = 3

    public required init(rawValue: StateRawValue, bluetoothManager: PumpBluetoothmanager) {
        state = TandemState(rawValue: rawValue)
        client = Self.makeClient(state)
        installer = Self.makeInstaller(state)
        bluetooth = TandemBluetoothManager(pumpBluetoothManager: bluetoothManager)
        bluetooth.api = client
        bluetooth.onStatusChange = { [weak self] status in
            guard let self else {
                return
            }
            lock.lock()
            bridgeStatus = status
            lock.unlock()
            notifyStateDidUpdate()
        }

        capabilities.actions = makeActions()
        capabilities.sliders = makeSliders()
    }

    public func startAdvertising() {
        if state.activatedAt == nil {
            state.activatedAt = Date.now
        }
        isRunning = true
        bluetooth.start(endpoint: VirtualGattEndpoint(state.gattEndpoint) ?? .default)
        startPolling()
        notifyStateDidUpdate()
    }

    public func reset() {
        state = TandemState(rawValue: [:])
        client = Self.makeClient(state)
        bluetooth.api = client
        lock.lock()
        snapshot = nil
        snapshotError = nil
        suspendedSince = nil
        lock.unlock()
        // faketandem forgets its long-term key and session on a pairing code write, the same code included.
        perform("forget pairing on faketandem") { client in
            try client.updateState(["pairing_code": client.snapshot().auth.pairingCode])
        }
        notifyStateDidUpdate()
    }

    public func stop() {
        guard isRunning else {
            return
        }
        isRunning = false
        pollTimer?.cancel()
        pollTimer = nil
        bluetooth.stop()
        workQueue.async {
            self.faketandem?.stop()
            self.faketandem = nil
            self.lastLaunch = nil
            self.exitsInARow = 0
            self.setFaketandemStatus(nil)
        }
        logger.info("Tandem simulator has been stopped!")
    }

    func notifyStateDidUpdate() {
        storageDelegate?.saveState(TandemPumpManager.self, self)
    }

    private static func makeClient(_ state: TandemState) -> FaketandemClient {
        FaketandemClient(baseURL: URL(string: state.apiURL) ?? FaketandemClient.defaultBaseURL)
    }

    /// The tab starts faketandem only at this Mac's loopback addresses, the defaults; any other
    /// address is a faketandem run elsewhere.
    private static func makeInstaller(_ state: TandemState) -> FaketandemInstaller? {
        guard let release = FaketandemRelease.configured(),
              let api = URL(string: state.apiURL), isLoopback(api.host),
              let gatt = VirtualGattEndpoint(state.gattEndpoint), isLoopback(gatt.host)
        else {
            return nil
        }
        return FaketandemInstaller(release: release)
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host else {
            return false
        }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    private func current() -> (snapshot: FaketandemSnapshot?, error: String?, status: TandemBluetoothManager.Status) {
        lock.lock()
        defer { lock.unlock() }
        return (snapshot, snapshotError, bridgeStatus)
    }

    private var currentFaketandemStatus: String? {
        lock.lock()
        defer { lock.unlock() }
        return faketandemStatus
    }

    private func setFaketandemStatus(_ status: String?) {
        lock.lock()
        faketandemStatus = status
        lock.unlock()
        notifyStateDidUpdate()
    }

    // MARK: - faketandem's state

    private func startPolling() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        timer.resume()
        pollTimer = timer
    }

    private func refresh() {
        do {
            let snapshot = try client.snapshot()
            lock.lock()
            if snapshot.basal.suspended {
                if suspendedSince == nil {
                    suspendedSince = Date()
                }
            } else {
                suspendedSince = nil
            }
            self.snapshot = snapshot
            snapshotError = nil
            lock.unlock()
            faketandemIsReachable()
        } catch {
            lock.lock()
            let wasReachable = snapshotError == nil
            snapshot = nil
            snapshotError = "\(error)"
            lock.unlock()
            if wasReachable {
                logger.warning("faketandem's API at \(state.apiURL) is not reachable: \(error)")
            }
            launchFaketandemIfNeeded()
        }
        notifyStateDidUpdate()
    }

    // MARK: - faketandem itself

    private func faketandemIsReachable() {
        exitsInARow = 0
        let someoneElses = "Using the faketandem already running at \(state.apiURL)"
        if installer != nil, faketandem == nil, currentFaketandemStatus != someoneElses {
            setFaketandemStatus(someoneElses)
        }
    }

    /// Fetches and starts faketandem while nothing answers at the API address: once per
    /// `launchRetryInterval`, and not after `launchExitLimit` exits in a row, which the log explains.
    private func launchFaketandemIfNeeded() {
        guard isRunning, let installer, faketandem == nil, exitsInARow < Self.launchExitLimit else {
            return
        }
        if let lastLaunch, Date().timeIntervalSince(lastLaunch) < Self.launchRetryInterval {
            return
        }
        lastLaunch = Date()
        do {
            let binary = try installer.install { [weak self] step in
                self?.setFaketandemStatus(step.prefix(1).uppercased() + step.dropFirst())
            }
            let version = FaketandemProcess.version(of: binary) ?? installer.release.tag
            let process = FaketandemProcess(binary: binary, apiAddress: apiAddress, gattAddress: state.gattEndpoint, logger: logger)
            process.onExit = { [weak self, weak process] status in
                guard let process else {
                    return
                }
                self?.faketandemExited(process, status: status)
            }
            try process.start()
            faketandem = process
            setFaketandemStatus("Running faketandem \(version), started by the tab")
        } catch {
            setFaketandemStatus("Could not start faketandem \(installer.release.tag): \(error)")
            logger.error("Could not start faketandem \(installer.release.tag): \(error)")
        }
    }

    private func faketandemExited(_ process: FaketandemProcess, status: Int32) {
        workQueue.async {
            guard self.faketandem === process else {
                return
            }
            self.faketandem = nil
            self.exitsInARow += 1
            if self.exitsInARow < Self.launchExitLimit {
                self.setFaketandemStatus("faketandem exited with status \(status); starting it again")
            } else {
                self.setFaketandemStatus("faketandem exited with status \(status), \(self.exitsInARow) times in a row; see the log, then stop and start the tab")
            }
        }
    }

    /// `host:port` for faketandem's `-api-addr`, from the URL the tab polls.
    private var apiAddress: String {
        "\(client.baseURL.host ?? "127.0.0.1"):\(client.baseURL.port ?? 80)"
    }

    /// Runs a call against faketandem off the main thread, and shows the result at once.
    private func perform(_ what: String, _ work: @escaping (FaketandemClient) throws -> Void) {
        workQueue.async {
            do {
                try work(self.client)
                self.logger.info("\(what): done")
            } catch {
                self.logger.error("\(what) failed: \(error)")
            }
            self.refresh()
        }
    }

    private func makeActions() -> [PumpManagerActions] {
        [
            PumpManagerActions(label: "Pairing state: PairStep2 (connectable)") { [weak self] in
                self?.perform("pairing state PairStep2") { try $0.setPairingState("PairStep2") }
            },
            PumpManagerActions(label: "Pairing state: NotDiscoverable") { [weak self] in
                self?.perform("pairing state NotDiscoverable") { try $0.setPairingState("NotDiscoverable") }
            },
            PumpManagerActions(label: "New pairing code") { [weak self] in
                let code = String(format: "%06d", Int.random(in: 0 ..< 1_000_000))
                self?.perform("pairing code \(code)") { try $0.updateState(["pairing_code": code]) }
            },
            PumpManagerActions(label: "Bolus 1.0 U from the pump") { [weak self] in
                self?.perform("pump bolus") { try $0.action("bolus/start", ["units": 1.0, "source": "pump"]) }
            },
            PumpManagerActions(label: "Cancel bolus") { [weak self] in
                self?.perform("cancel bolus") { try $0.action("bolus/abort") }
            },
            PumpManagerActions(label: "Temp basal 150% for 30 min") { [weak self] in
                self?.perform("temp basal") { try $0.action("tempbasal/start", ["percent": 150, "duration_minutes": 30]) }
            },
            PumpManagerActions(label: "Stop temp basal") { [weak self] in
                self?.perform("stop temp basal") { try $0.action("tempbasal/stop") }
            },
            PumpManagerActions(label: "Suspend") { [weak self] in
                self?.perform("suspend") { try $0.action("suspend", ["reason": "user"]) }
            },
            PumpManagerActions(label: "Occlusion alarm") { [weak self] in
                self?.perform("occlusion") { try $0.action("suspend", ["reason": "occlusion"]) }
            },
            PumpManagerActions(label: "Resume") { [weak self] in
                self?.perform("resume") { try $0.action("resume") }
            },
            PumpManagerActions(label: "Open faketandem web UI") { [weak self] in
                self?.openWebUI()
            },
            PumpManagerActions(label: "Reconnect to faketandem") { [weak self] in
                guard let self, isRunning else {
                    return
                }
                bluetooth.stop()
                bluetooth.start(endpoint: VirtualGattEndpoint(state.gattEndpoint) ?? .default)
            },
        ]
    }

    private func makeSliders() -> [PumpManagerSlider] {
        [
            PumpManagerSlider(
                label: "Reservoir",
                range: 0 ... 300,
                step: 5,
                unit: "U",
                get: { [weak self] in self?.current().snapshot?.insulin.reservoirUnits ?? 0 },
                set: { [weak self] units in
                    self?.perform("reservoir \(units) U") { try $0.updateState(["reservoir_units": units]) }
                }
            ),
            PumpManagerSlider(
                label: "Battery",
                range: 0 ... 100,
                step: 5,
                unit: "%",
                get: { [weak self] in Double(self?.current().snapshot?.battery.percentage ?? 0) },
                set: { [weak self] percent in
                    self?.perform("battery \(Int(percent))%") { try $0.updateState(["battery_percent": Int(percent)]) }
                }
            ),
        ]
    }

    private func openWebUI() {
        guard let url = URL(string: "ui/", relativeTo: client.baseURL)?.absoluteURL else {
            return
        }
        #if canImport(AppKit)
            _ = NSWorkspace.shared.open(url)
        #else
            logger.info("faketandem web UI: \(url)")
        #endif
    }
}
