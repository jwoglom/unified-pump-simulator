import CoreBluetooth

protocol BluetoothManagerDelegate {
    func didStartAdvertising(_ error: (any Error)?)
    func didReceiveWrite(_ peripheral: CBPeripheralManager, characteristic: CBCharacteristic, data: Data, request: CBATTRequest)
    func didReceiveSubscribe(central: CBCentral, peripheralManager: CBPeripheralManager)
    func didUnsubscribe(central: CBCentral)
    func readyForNextMessage(_ peripheral: CBPeripheralManager)

    /// Every request of one ATT write together: a long write arrives as several, with offsets, and
    /// is answered once, on its first request. The default hands each to `didReceiveWrite`.
    func didReceiveWrites(_ peripheral: CBPeripheralManager, requests: [CBATTRequest])
    func didReceiveSubscribe(central: CBCentral, characteristic: CBCharacteristic, peripheralManager: CBPeripheralManager)
    func didUnsubscribe(central: CBCentral, characteristic: CBCharacteristic)
    /// Answers the read, with `respond(to:withResult:)`, and returns true; false leaves it refused.
    func didReceiveRead(_ peripheral: CBPeripheralManager, request: CBATTRequest) -> Bool
}

extension BluetoothManagerDelegate {
    func didReceiveWrites(_ peripheral: CBPeripheralManager, requests: [CBATTRequest]) {
        for item in requests {
            guard let value = item.value else {
                return
            }
            didReceiveWrite(peripheral, characteristic: item.characteristic, data: value, request: item)
        }
    }

    func didReceiveSubscribe(central: CBCentral, characteristic _: CBCharacteristic, peripheralManager: CBPeripheralManager) {
        didReceiveSubscribe(central: central, peripheralManager: peripheralManager)
    }

    func didUnsubscribe(central: CBCentral, characteristic _: CBCharacteristic) {
        didUnsubscribe(central: central)
    }

    func didReceiveRead(_: CBPeripheralManager, request _: CBATTRequest) -> Bool {
        false
    }
}

public class PumpBluetoothmanager: NSObject {
    var bluetoothManagerDelegate: BluetoothManagerDelegate?
    var peripheralManager: CBPeripheralManager?
    let managerQueue = DispatchQueue(label: "com.bastiaanv.bluetoothManagerQueue", qos: .unspecified)

    private let logger = PumpManagerLogger(subsystem: "com.bastiaanv.utils", category: "PumpBluetoothManager")

    override public init() {
        super.init()

        managerQueue.sync {
            self.peripheralManager = CBPeripheralManager(delegate: self, queue: managerQueue)
        }
    }

    public func startAdvertising(services: [CBMutableService], advertisingData: [String: Any]) {
        guard let peripheralManager = peripheralManager else {
            logger.error("No CBPeripheralManager available...")
            return
        }

        guard peripheralManager.state == .poweredOn else {
            logger.error("CBPeripheralManager is in an invalid state - state: \(peripheralManager.state.rawValue)")
            return
        }

        peripheralManager.removeAllServices()

        for service in services {
            peripheralManager.add(service)
        }

        peripheralManager.startAdvertising(advertisingData)
    }

    public func stopAdvertising() {
        peripheralManager?.stopAdvertising()
    }
}

extension PumpBluetoothmanager: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        logger.info("peripheralManagerDidUpdateState: \(peripheral.state.rawValue)")
    }

    public func peripheralManager(_: CBPeripheralManager, didAdd _: CBService, error: (any Error)?) {
        if let error = error {
            logger.error("Got error during didAdd service - error: \(error.localizedDescription)")
        }
    }

    public func peripheralManager(
        _ peripheralManager: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        logger.debug("Received subscription from \(central) on \(characteristic.uuid.uuidString)")
        bluetoothManagerDelegate?.didReceiveSubscribe(
            central: central,
            characteristic: characteristic,
            peripheralManager: peripheralManager
        )
    }

    public func peripheralManager(
        _: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        logger.debug("Received unsubscription from \(central) on \(characteristic.uuid.uuidString)")
        bluetoothManagerDelegate?.didUnsubscribe(central: central, characteristic: characteristic)
    }

    public func peripheralManagerDidStartAdvertising(_: CBPeripheralManager, error: (any Error)?) {
        bluetoothManagerDelegate?.didStartAdvertising(error)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for item in requests where item.value == nil {
            let message = "EMPTY data received - UUID: \(item.characteristic.uuid.uuidString), Service uuid: \(item.characteristic.service?.uuid.uuidString ?? "nil")"
            logger.warning(message)
        }

        bluetoothManagerDelegate?.didReceiveWrites(peripheral, requests: requests)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if bluetoothManagerDelegate?.didReceiveRead(peripheral, request: request) == true {
            return
        }
        peripheral.respond(to: request, withResult: .readNotPermitted)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheralManager: CBPeripheralManager) {
        bluetoothManagerDelegate?.readyForNextMessage(peripheralManager)
    }
}
