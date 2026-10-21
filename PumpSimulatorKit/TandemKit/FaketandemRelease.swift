import Foundation

/// A faketandem build on GitHub Releases: `latest` follows the newest push to faketandem's main
/// branch, `main-<date>-<sha>` pins one, `v*` is a tagged release. Each asset is the static binary
/// itself, with the web UI built in, listed in the release's `SHA256SUMS`.
struct FaketandemRelease: Equatable {
    /// `FAKETANDEM_RELEASE` in the app's environment picks the release; `none` leaves starting
    /// faketandem to the developer.
    static let environmentVariable = "FAKETANDEM_RELEASE"
    static let defaultTag = "latest"
    static let noneTag = "none"
    static let defaultRepository = URL(string: "https://github.com/jwoglom/faketandem")!

    /// Go's name for this machine: macOS is `darwin`, Intel is `amd64`.
    static let platform: String = {
        #if os(macOS)
            let os = "darwin"
        #elseif os(Linux)
            let os = "linux"
        #else
            let os = "unsupported"
        #endif
        #if arch(arm64)
            return "\(os)-arm64"
        #elseif arch(x86_64)
            return "\(os)-amd64"
        #else
            return "\(os)-unsupported"
        #endif
    }()

    let tag: String
    var repository = FaketandemRelease.defaultRepository

    static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) -> FaketandemRelease? {
        let tag = environment[environmentVariable] ?? defaultTag
        return tag == noneTag ? nil : FaketandemRelease(tag: tag)
    }

    var assetName: String {
        "faketandem-\(tag)-\(Self.platform)"
    }

    var checksumsURL: URL {
        asset("SHA256SUMS")
    }

    var binaryURL: URL {
        asset(assetName)
    }

    private func asset(_ name: String) -> URL {
        URL(string: "\(repository.absoluteString)/releases/download/\(tag)/\(name)")!
    }
}
