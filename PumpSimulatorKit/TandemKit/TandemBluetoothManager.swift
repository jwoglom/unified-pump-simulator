import CoreBluetooth
import Foundation

/// A real Bluetooth peripheral standing in for faketandem: it publishes the GATT table faketandem
/// announces, forwards the central's subscriptions, writes and reads over the virtual GATT link,
/// and delivers the pump's notifications. One BLE connection is one link connection, as the link
/// protocol has it, so faketandem sees each phone come and go as a pump would.
final class TandemBluetoothManager {
    static let pumpService = CBUUID(string: "0000FDFB-0000-1000-8000-00805F9B34FB")

    /// `Tandem Mobi 123` is advertised as `SIM Tandem Mobi 123`. A CoreBluetooth peripheral cannot
    /// advertise manufacturer data, which is where TandemKit reads a pump's pairing step, so TandemKit
    /// takes a name starting with `SIM` as a simulator that is ready for its code.
    static func advertisedName(for pumpName: String) -> String {
        "SIM \(pumpName)"
    }

    enum Status: Equatable {
        case stopped
        /// faketandem is not reachable, or not discoverable; the link is retried.
        case waitingForFaketandem(String)
        case bluetoothUnavailable
        case advertising(name: String)
        case centralConnected(name: String)
        /// faketandem ended the link while a phone was connected.
        case linkLost(String)
    }

    var onStatusChange: ((Status) -> Void)?
    /// Lets the pump's notification size follow the phone's (`matchNotificationSize`).
    var api: FaketandemClient?

    private(set) var status: Status = .stopped {
        didSet {
            if status != oldValue {
                onStatusChange?(status)
            }
        }
    }

    private let logger = PumpManagerLogger(subsystem: "com.bastiaanv.tandemkit", category: "TandemBluetoothManager")
    private let pumpBluetoothManager: PumpBluetoothmanager
    private let queue = DispatchQueue(label: "com.bastiaanv.tandemkit.bridge")
    private var endpoint = VirtualGattEndpoint.default
    private var running = false
    private var retry: DispatchWorkItem?

    private var hello: VirtualGattHello?
    private var name = ""
    /// What faketandem's readable characteristics (Device Information) hold, by normalized UUID.
    private var cachedValues: [String: Data] = [:]
    private var characteristics: [String: CBMutableCharacteristic] = [:]

    private var link: VirtualGattLink?
    private var linkToken: UUID?
    private var central: CBCentral?
    private var subscribed: Set<String> = []
    private var notifications: [(value: Data, characteristic: CBMutableCharacteristic)] = []

    init(pumpBluetoothManager: PumpBluetoothmanager) {
        self.pumpBluetoothManager = pumpBluetoothManager
    }

    func start(endpoint: VirtualGattEndpoint) {
        queue.async {
            self.endpoint = endpoint
            self.running = true
            self.pumpBluetoothManager.bluetoothManagerDelegate = self
            self.prepare()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.retry?.cancel()
            self.retry = nil
            self.endLink(disconnect: true)
            self.pumpBluetoothManager.stopAdvertising()
            self.pumpBluetoothManager.peripheralManager?.removeAllServices()
            self.hello = nil
            self.cachedValues = [:]
            self.characteristics = [:]
            self.status = .stopped
        }
    }

    // MARK: - Bringing the peripheral up

    /// Dials faketandem for its GATT table and the values of its readable characteristics, then
    /// advertises. Retried until faketandem is reachable and discoverable: it refuses every
    /// connection, this one included, while NotDiscoverable.
    private func prepare() {
        guard running else {
            return
        }
        let link: VirtualGattLink
        do {
            link = try VirtualGattLink(endpoint: endpoint, eventQueue: queue) { _ in }
        } catch {
            waitForFaketandem("faketandem is not reachable at \(endpoint.description): \(error)")
            return
        }
        guard link.hello.isDiscoverable else {
            link.close()
            waitForFaketandem("faketandem is \(link.hello.pairingState); set its pairing state (PairStep2) to make it connectable")
            return
        }

        var values: [String: Data] = [:]
        for service in link.hello.services where !Self.isSystemService(service.uuid) {
            for characteristic in service.characteristics where characteristic.isReadable {
                do {
                    values[characteristic.uuid] = try link.read(characteristic: characteristic.uuid)
                } catch {
                    logger.warning("Could not read \(characteristic.uuid) from faketandem: \(error)")
                }
            }
        }
        link.close()

        hello = link.hello
        name = Self.advertisedName(for: link.hello.name)
        cachedValues = values
        logger.info("faketandem at \(endpoint.description) is \(link.hello.name) (\(link.hello.pairingState))")
        advertise()
    }

    private func waitForFaketandem(_ reason: String) {
        if status != .waitingForFaketandem(reason) {
            logger.warning(reason)
        }
        status = .waitingForFaketandem(reason)
        scheduleRetry(after: 5) { $0.prepare() }
    }

    private func scheduleRetry(after seconds: TimeInterval, _ work: @escaping (TandemBluetoothManager) -> Void) {
        retry?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running else {
                return
            }
            work(self)
        }
        retry = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// CoreBluetooth publishes Generic Access and Generic Attribute itself and refuses them from an app.
    private static func isSystemService(_ uuid: String) -> Bool {
        uuid == VirtualGattLink.normalize(uuid: "1800") || uuid == VirtualGattLink.normalize(uuid: "1801")
    }

    private func advertise() {
        guard running, let hello else {
            return
        }
        guard let manager = pumpBluetoothManager.peripheralManager, manager.state == .poweredOn else {
            if status != .bluetoothUnavailable {
                logger.warning("Bluetooth is not powered on; waiting")
            }
            status = .bluetoothUnavailable
            scheduleRetry(after: 1) { $0.advertise() }
            return
        }

        pumpBluetoothManager.startAdvertising(
            services: buildServices(hello),
            advertisingData: [
                CBAdvertisementDataLocalNameKey: name,
                CBAdvertisementDataServiceUUIDsKey: [Self.pumpService],
            ]
        )
        status = .advertising(name: name)
    }

    private func buildServices(_ hello: VirtualGattHello) -> [CBMutableService] {
        characteristics = [:]
        var services: [CBMutableService] = []
        for service in hello.services where !Self.isSystemService(service.uuid) {
            let mutableService = CBMutableService(type: CBUUID(string: service.uuid), primary: true)
            mutableService.characteristics = service.characteristics.map { characteristic in
                var properties: CBCharacteristicProperties = []
                var permissions: CBAttributePermissions = []
                for property in characteristic.properties {
                    switch property {
                    case VirtualGattCharacteristic.read:
                        properties.insert(.read)
                        permissions.insert(.readable)
                    case VirtualGattCharacteristic.write:
                        properties.insert(.write)
                        permissions.insert(.writeable)
                    case VirtualGattCharacteristic.writeWithoutResponse:
                        properties.insert(.writeWithoutResponse)
                        permissions.insert(.writeable)
                    case VirtualGattCharacteristic.notify:
                        properties.insert(.notify)
                    case VirtualGattCharacteristic.indicate:
                        properties.insert(.indicate)
                    default:
                        break
                    }
                }
                // CoreBluetooth answers reads of a cached value itself, and takes one only on a
                // read-only characteristic.
                let cached = properties == .read ? cachedValues[characteristic.uuid] : nil
                let mutableCharacteristic = CBMutableCharacteristic(
                    type: CBUUID(string: characteristic.uuid),
                    properties: properties,
                    value: cached,
                    permissions: permissions
                )
                characteristics[characteristic.uuid] = mutableCharacteristic
                return mutableCharacteristic
            }
            services.append(mutableService)
        }
        return services
    }

    // MARK: - One phone, one link

    /// Opens the link for the phone's connection on its first request, as the pump would accept the
    /// connection then. A second phone is refused: the pump has one link.
    private func ensureAttached(_ central: CBCentral) -> Bool {
        if link != nil, let attached = self.central {
            if attached.identifier == central.identifier {
                return true
            }
            logger.warning("Refusing central \(central.identifier): \(attached.identifier) holds the pump")
            return false
        }

        let token = UUID()
        do {
            let link = try VirtualGattLink(endpoint: endpoint, eventQueue: queue) { [weak self] event in
                self?.handle(event, from: token)
            }
            guard link.hello.isDiscoverable else {
                link.close()
                logger.warning("faketandem is \(link.hello.pairingState); the phone's requests are refused, as the pump would")
                return false
            }
            matchNotificationSize(to: central)
            try link.attach()
            self.link = link
            linkToken = token
            self.central = central
            status = .centralConnected(name: name)
            logger.info("Central \(central.identifier) connected; attached to faketandem")
            return true
        } catch {
            logger.error("Could not connect the phone to faketandem: \(error)")
            return false
        }
    }

    /// A Mobi and an iPhone negotiate a large MTU, so most responses reach the phone as a single
    /// notification. faketandem fragments to the MTU it is told, so tell it the phone's.
    private func matchNotificationSize(to central: CBCentral) {
        guard let api else {
            return
        }
        let mtu = min(517, central.maximumUpdateValueLength + 3)
        do {
            try api.setATTMTU(mtu)
            logger.info("faketandem ATT MTU set to \(mtu): notifications of up to \(central.maximumUpdateValueLength) bytes")
        } catch {
            logger.warning("Could not set faketandem's ATT MTU (\(error)); it fragments to its own")
        }
    }

    private func handle(_ event: VirtualGattEvent, from token: UUID) {
        guard token == linkToken else {
            return
        }
        switch event {
        case let .notify(uuid, value):
            guard let characteristic = characteristics[uuid] else {
                logger.warning("Notification on unknown characteristic \(uuid)")
                return
            }
            if let central, value.count > central.maximumUpdateValueLength {
                logger.error("Dropping a \(value.count)-byte notification on \(uuid): the phone takes at most \(central.maximumUpdateValueLength)")
                return
            }
            logger.debug("Notify on \(uuid): \(value.hexString())")
            notifications.append((value, characteristic))
            flushNotifications()

        case let .disconnected(reason):
            let reason = reason ?? "link closed"
            logger.warning("faketandem ended the link: \(reason)")
            link = nil
            linkToken = nil
            if central != nil {
                status = .linkLost(reason)
                dropCentral()
            } else {
                status = .advertising(name: name)
            }
        }
    }

    /// CoreBluetooth cannot end a connection from the peripheral's side. Withdrawing the services
    /// invalidates them on the phone, whose next request fails, and they are published again.
    private func dropCentral() {
        central = nil
        subscribed = []
        notifications = []
        pumpBluetoothManager.stopAdvertising()
        pumpBluetoothManager.peripheralManager?.removeAllServices()
        scheduleRetry(after: 1) { $0.prepare() }
    }

    private func flushNotifications() {
        guard let manager = pumpBluetoothManager.peripheralManager else {
            return
        }
        while let next = notifications.first {
            // Refused when the transmit queue is full; readyForNextMessage retries, in order.
            guard manager.updateValue(next.value, for: next.characteristic, onSubscribedCentrals: nil) else {
                return
            }
            notifications.removeFirst()
        }
    }

    private func endLink(disconnect: Bool) {
        if let link {
            if disconnect {
                link.disconnect()
            } else {
                link.close()
            }
        }
        link = nil
        linkToken = nil
        central = nil
        subscribed = []
        notifications = []
    }

    private static func normalized(_ uuid: CBUUID) -> String {
        VirtualGattLink.normalize(uuid: uuid.uuidString)
    }
}

// MARK: - BluetoothManagerDelegate

extension TandemBluetoothManager: BluetoothManagerDelegate {
    func didStartAdvertising(_ error: (any Error)?) {
        if let error {
            logger.error("Failed to start advertising: \(error.localizedDescription)")
            queue.async {
                self.scheduleRetry(after: 2) { $0.advertise() }
            }
            return
        }
        logger.info("Advertising as \(name) for faketandem at \(endpoint.description)")
    }

    func didReceiveWrite(_: CBPeripheralManager, characteristic _: CBCharacteristic, data _: Data, request _: CBATTRequest) {}

    func didReceiveWrites(_ peripheral: CBPeripheralManager, requests: [CBATTRequest]) {
        guard let first = requests.first else {
            return
        }
        // A long write arrives as pieces with offsets, answered once on the first.
        var value = Data()
        for request in requests.sorted(by: { $0.offset < $1.offset }) {
            guard let piece = request.value else {
                continue
            }
            if request.offset != value.count {
                logger.warning("Write piece at offset \(request.offset) after \(value.count) bytes")
            }
            value.append(piece)
        }
        let uuid = Self.normalized(first.characteristic.uuid)
        let payload = value

        queue.async {
            guard self.ensureAttached(first.central) else {
                peripheral.respond(to: first, withResult: .unlikelyError)
                return
            }
            // Real-pump ordering: the write is acknowledged before any response notification.
            peripheral.respond(to: first, withResult: .success)
            self.logger.debug("Write on \(uuid): \(payload.hexString())")
            self.link?.write(characteristic: uuid, value: payload, withResponse: true)
        }
    }

    func didReceiveSubscribe(central _: CBCentral, peripheralManager _: CBPeripheralManager) {}

    func didReceiveSubscribe(central: CBCentral, characteristic: CBCharacteristic, peripheralManager _: CBPeripheralManager) {
        let uuid = Self.normalized(characteristic.uuid)
        queue.async {
            guard self.ensureAttached(central) else {
                return
            }
            self.subscribed.insert(uuid)
            self.link?.subscribe(characteristic: uuid, enabled: true)
        }
    }

    func didUnsubscribe(central _: CBCentral) {}

    func didUnsubscribe(central: CBCentral, characteristic: CBCharacteristic) {
        let uuid = Self.normalized(characteristic.uuid)
        queue.async {
            self.subscribed.remove(uuid)
            self.link?.subscribe(characteristic: uuid, enabled: false)
            // A phone that disconnects is unsubscribed from everything by CoreBluetooth.
            if self.subscribed.isEmpty, self.link != nil {
                self.logger.info("Central \(central.identifier) left; disconnecting from faketandem")
                self.endLink(disconnect: true)
                self.status = .advertising(name: self.name)
            }
        }
    }

    func didReceiveRead(_ peripheral: CBPeripheralManager, request: CBATTRequest) -> Bool {
        let uuid = Self.normalized(request.characteristic.uuid)
        queue.async {
            var value = self.cachedValues[uuid]
            if value == nil, self.ensureAttached(request.central), let link = self.link {
                do {
                    value = try link.read(characteristic: uuid)
                } catch {
                    self.logger.warning("Read of \(uuid) failed: \(error)")
                }
            }
            guard let value else {
                peripheral.respond(to: request, withResult: .readNotPermitted)
                return
            }
            guard request.offset <= value.count else {
                peripheral.respond(to: request, withResult: .invalidOffset)
                return
            }
            request.value = value.subdata(in: request.offset ..< value.count)
            peripheral.respond(to: request, withResult: .success)
        }
        return true
    }

    func readyForNextMessage(_: CBPeripheralManager) {
        queue.async {
            self.flushNotifications()
        }
    }
}
