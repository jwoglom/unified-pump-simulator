import Foundation

/// A faketandem the tab runs, on the virtual transport at the tab's addresses. It is started under a
/// shell that kills it once the pipe the app holds on its stdin closes: `stop()` closes it, and so
/// does the app's death, Xcode's Stop included, so no faketandem outlives the app.
final class FaketandemProcess {
    /// $1 the binary, $2 the API address, $3 the link address. faketandem reads nothing from stdin, so
    /// a subshell reads the pipe until it closes, on the shell's own stdin: a background command's is
    /// /dev/null unless redirected. It is the shell itself that reads, so nothing outlives the shell to
    /// hold its pipes open.
    static let watchdog = """
    exec 3<&0
    "$1" -transport virtual -q -api-addr "$2" -virtual-addr "$3" &
    pid=$!
    ( while read -r _; do :; done; kill "$pid" 2>/dev/null ) <&3 &
    wait "$pid"
    status=$?
    kill $! 2>/dev/null
    exit "$status"
    """

    let binary: URL
    let apiAddress: String
    let gattAddress: String
    /// faketandem's exit status, on the pipe's queue.
    var onExit: ((Int32) -> Void)?

    private let logger: PumpManagerLogger
    private let lock = NSLock()
    private var process: Process?
    private var input: Pipe?
    private var partialLine = Data()

    init(binary: URL, apiAddress: String, gattAddress: String, logger: PumpManagerLogger) {
        self.binary = binary
        self.apiAddress = apiAddress
        self.gattAddress = gattAddress
        self.logger = logger
    }

    deinit {
        stop()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// What `faketandem -version` prints: the tag, or `main-<date>-<sha>` for a `latest` build.
    static func version(of binary: URL) -> String? {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !version.isEmpty ? version : nil
    }

    func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.watchdog, "faketandem", binary.path, apiAddress, gattAddress]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.log(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            guard let self else {
                return
            }
            self.lock.lock()
            let input = self.input
            self.input = nil
            self.process = nil
            self.lock.unlock()
            try? input?.fileHandleForWriting.close()
            self.log(output.fileHandleForReading.readDataToEndOfFile())
            self.flushPartialLine()
            self.logger.info("faketandem exited with status \(process.terminationStatus)")
            self.onExit?(process.terminationStatus)
        }
        try process.run()
        lock.lock()
        self.process = process
        self.input = input
        lock.unlock()
        logger.info("Started faketandem \(binary.lastPathComponent), API on \(apiAddress), link on \(gattAddress)")
    }

    func stop() {
        lock.lock()
        let input = self.input
        self.input = nil
        lock.unlock()
        try? input?.fileHandleForWriting.close()
    }

    private func log(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        lock.lock()
        partialLine.append(data)
        var lines: [String] = []
        while let newline = partialLine.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: partialLine[partialLine.startIndex ..< newline], as: UTF8.self))
            partialLine.removeSubrange(partialLine.startIndex ... newline)
        }
        lock.unlock()
        lines.forEach(logLine)
    }

    private func flushPartialLine() {
        lock.lock()
        let rest = partialLine
        partialLine = Data()
        lock.unlock()
        if !rest.isEmpty {
            logLine(String(decoding: rest, as: UTF8.self))
        }
    }

    /// faketandem colours its log even into a pipe, with logrus's four-letter levels.
    private func logLine(_ raw: String) {
        let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        guard !line.isEmpty else {
            return
        }
        if line.hasPrefix("FATA") || line.hasPrefix("ERRO") || line.hasPrefix("PANI") {
            logger.error("faketandem: \(line)")
        } else if line.hasPrefix("WARN") {
            logger.warning("faketandem: \(line)")
        } else {
            logger.debug("faketandem: \(line)")
        }
    }
}
