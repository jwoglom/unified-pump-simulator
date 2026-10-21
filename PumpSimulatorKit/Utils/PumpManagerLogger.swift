import OSLog

public struct LogLine: Identifiable {
    public let id = UUID()
    public let level: String
    public let message: String
    public let submessage: String
    public let functionInfo: String
}

public class PumpManagerLogger {
    private let logger: Logger
    private static var observers: [LoggerObserver] = []
    /// Kits log from their Bluetooth, link and worker queues at once.
    private static let lock = NSLock()

    public private(set) static var logLines: [LogLine] = [] {
        didSet {
            observers.forEach { $0.logsUpdated(logLines) }
        }
    }

    private static func append(_ line: LogLine) {
        lock.lock()
        defer { lock.unlock() }
        logLines.append(line)
    }

    init(subsystem: String, category: String) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public static func addObserver(_ observer: LoggerObserver) {
        observers.append(observer)
    }

    func debug(_ message: String, _ file: String = #file, _ function: String = #function, _ line: Int = #line) {
        let (submessage, functionInfo) = formatMessage("DEBUG", file, function, line)
        logger.debug("[\(submessage)] \(functionInfo): \(message, privacy: .public)")
        PumpManagerLogger.append(LogLine(
            level: "DEBUG",
            message: message,
            submessage: submessage,
            functionInfo: functionInfo
        ))
    }

    func info(_ message: String, _ file: String = #file, _ function: String = #function, _ line: Int = #line) {
        let (submessage, functionInfo) = formatMessage("INFO", file, function, line)
        logger.info("[\(submessage)] \(functionInfo): \(message, privacy: .public)")
        PumpManagerLogger.append(LogLine(
            level: "INFO",
            message: message,
            submessage: submessage,
            functionInfo: functionInfo
        ))
    }

    func warning(_ message: String, _ file: String = #file, _ function: String = #function, _ line: Int = #line) {
        let (submessage, functionInfo) = formatMessage("WARNING", file, function, line)
        logger.warning("[\(submessage)] \(functionInfo): \(message, privacy: .public)")
        PumpManagerLogger.append(LogLine(
            level: "WARNING",
            message: message,
            submessage: submessage,
            functionInfo: functionInfo
        ))
    }

    func error(_ message: String, _ file: String = #file, _ function: String = #function, _ line: Int = #line) {
        let (submessage, functionInfo) = formatMessage("ERROR", file, function, line)
        logger.error("[\(submessage)] \(functionInfo): \(message, privacy: .public)")
        PumpManagerLogger.append(LogLine(
            level: "ERROR",
            message: message,
            submessage: submessage,
            functionInfo: functionInfo
        ))
    }

    private func formatMessage(_ lvl: String, _ file: String, _ function: String, _ line: Int) -> (String, String) {
        (
            "\(dateFormatter.string(from: Date())) \(lvl)",
            "\(file.file) - \(function)#\(line)"
        )
    }

    private var dateFormatter: DateFormatter {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return dateFormatter
    }
}

private extension String {
    var file: String {
        components(separatedBy: "/").last ?? ""
    }
}

public protocol LoggerObserver {
    func logsUpdated(_ lines: [LogLine])
}
