import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

enum FaketandemInstallError: Error, CustomStringConvertible {
    case request(URL, String)
    case status(URL, Int)
    case noChecksum(String)
    case checksum(String, expected: String, actual: String)

    var description: String {
        switch self {
        case let .request(url, reason):
            return "\(url.lastPathComponent): \(reason)"
        case let .status(url, code):
            return "\(url.lastPathComponent): HTTP \(code)"
        case let .noChecksum(asset):
            return "SHA256SUMS does not list \(asset)"
        case let .checksum(asset, expected, actual):
            return "\(asset) does not match SHA256SUMS: expected \(expected), got \(actual)"
        }
    }
}

/// Keeps a release's faketandem under the app's Application Support and checks it against the
/// release's SHA256SUMS at every start, so `latest` follows faketandem's main branch. The copy on
/// disk serves when GitHub cannot be reached.
final class FaketandemInstaller {
    /// Inside the App Sandbox this is the app's container.
    static var defaultDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("UnifiedPumpSimulator/faketandem", isDirectory: true)
    }

    let release: FaketandemRelease
    let directory: URL

    private let session: URLSession
    private let logger = PumpManagerLogger(subsystem: "com.bastiaanv.tandemkit", category: "FaketandemInstaller")

    init(release: FaketandemRelease, directory: URL = FaketandemInstaller.defaultDirectory, session: URLSession = .shared) {
        self.release = release
        self.directory = directory
        self.session = session
    }

    var binary: URL {
        directory.appendingPathComponent(release.assetName)
    }

    /// The binary to run, downloaded when the release's checksum differs from the copy on disk.
    func install(progress: (String) -> Void = { _ in }) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = binary
        let onDisk = FileManager.default.fileExists(atPath: binary.path)
        progress("checking faketandem \(release.tag) on GitHub")
        let expected: String
        do {
            expected = try expectedChecksum()
        } catch {
            guard onDisk else {
                throw error
            }
            logger.warning("Could not check faketandem \(release.tag) against GitHub (\(error)); using the copy on disk")
            return binary
        }
        if onDisk {
            if try Self.sha256(of: Data(contentsOf: binary)) == expected {
                return binary
            }
            logger.info("faketandem \(release.tag) has a newer build than the copy on disk")
        }

        progress("downloading \(release.assetName)")
        let data = try fetch(release.binaryURL, timeout: 300)
        let actual = Self.sha256(of: data)
        guard actual == expected else {
            throw FaketandemInstallError.checksum(release.assetName, expected: expected, actual: actual)
        }
        let staging = directory.appendingPathComponent(release.assetName + ".partial")
        try data.write(to: staging, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        Self.removeQuarantine(staging)
        if onDisk {
            try FileManager.default.removeItem(at: binary)
        }
        try FileManager.default.moveItem(at: staging, to: binary)
        logger.info("Installed faketandem \(release.tag) (\(data.count) bytes) at \(binary.path)")
        return binary
    }

    /// The asset's line of SHA256SUMS as sha256sum writes it: the digest, two spaces (an asterisk for
    /// a binary-mode read), the name.
    func expectedChecksum() throws -> String {
        let text = String(decoding: try fetch(release.checksumsURL, timeout: 20), as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else {
                continue
            }
            let name = fields[1].hasPrefix("*") ? fields[1].dropFirst() : fields[1][...]
            if name == release.assetName {
                return fields[0].lowercased()
            }
        }
        throw FaketandemInstallError.noChecksum(release.assetName)
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fetch(_ url: URL, timeout: TimeInterval) throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            outcome.data = data
            outcome.response = response as? HTTPURLResponse
            outcome.error = error
            done.signal()
        }.resume()
        done.wait()
        if let error = outcome.error {
            throw FaketandemInstallError.request(url, error.localizedDescription)
        }
        guard let response = outcome.response, let data = outcome.data else {
            throw FaketandemInstallError.request(url, "no response")
        }
        guard response.statusCode == 200 else {
            throw FaketandemInstallError.status(url, response.statusCode)
        }
        return data
    }

    /// A file the app writes is only quarantined if its Info.plist asks for it, and Gatekeeper refuses
    /// to run a quarantined binary, so the attribute is cleared wherever it was set.
    private static func removeQuarantine(_ file: URL) {
        #if os(macOS)
            _ = removexattr(file.path, "com.apple.quarantine", 0)
        #endif
    }
}

private final class Outcome: @unchecked Sendable {
    var data: Data?
    var response: HTTPURLResponse?
    var error: Error?
}
