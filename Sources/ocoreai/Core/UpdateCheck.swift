// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Release update check — the last honest surface a shipping app needs.
///
/// First principles: an app that ships (v0.1.6 is on GitHub Releases) owes
/// its users a way to KNOW a newer build exists. Auto-install is out of
/// scope (that's Sparkle + Developer ID signing territory); the honest
/// minimum is: check, compare, offer the release page. No nagging, no
/// silent downloads — the user decides.
///
/// Compares `AppInfo.shortVersion` (the running artifact's truth) against
/// the `tag_name` of `/releases/latest`. Version comparison is
/// numeric-segment aware so 0.10.0 > 0.9.0 (lex "<" would lie).
import Foundation

public enum UpdateCheck {
    public struct ReleaseInfo: Sendable, Equatable {
        public let version: String  // tag without leading "v"
        public let url: URL  // release page (browser opening is the caller's call)
        public let isPrerelease: Bool
    }

    public enum Outcome: Sendable, Equatable {
        case upToDate(current: String)
        case updateAvailable(current: String, release: ReleaseInfo)
        case unavailable(String)  // offline / rate-limited / parse failure
    }

    /// Numeric-aware compare: "0.10.0" > "0.9.0". Missing segments are 0.
    /// Returns true when `candidate` is strictly newer than `current`.
    public static func candidateIsNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate)
        let b = parts(current)
        for i in 0 ..< max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Parse a GitHub releases API payload. Pure so the honesty of the
    /// contract is testable without the network.
    public static func parseReleaseJSON(_ data: Data) -> Result<ReleaseInfo, Error> {
        guard
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let tag = json["tag_name"] as? String,
            let html = json["html_url"] as? String,
            let url = URL(string: html)
        else {
            return .failure(
                NSError(
                    domain: "UpdateCheck", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "malformed release JSON"]))
        }
        return .success(
            ReleaseInfo(
                version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                url: url,
                isPrerelease: (json["prerelease"] as? Bool) ?? false))
    }

    /// Latest release straight from GitHub. `latestURL` is injectable for
    /// tests (the network itself is not mocked here — this is a thin,
    /// honest reader of the public releases API; 60 req/h unauthenticated
    /// is ample for an explicit user action).
    public static func latestRelease(
        latestURL: URL = URL(string: "https://api.github.com/repos/uingei/ocoreai/releases/latest")!
    ) async -> Result<ReleaseInfo, Error> {
        do {
            var req = URLRequest(url: latestURL)
            req.setValue(
                "application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue(AppInfo.shortVersion, forHTTPHeaderField: "X-Client-Version")
            req.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return .failure(
                    NSError(
                        domain: "UpdateCheck", code: code,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"]))
            }
            return parseReleaseJSON(data)
        } catch {
            return .failure(error)
        }
    }

    /// One-shot check used by the About pane.
    public static func check() async -> Outcome {
        let current = AppInfo.shortVersion
        switch await latestRelease() {
        case .failure(let error):
            return .unavailable(error.localizedDescription)
        case .success(let release):
            // Prereleases are not advertised to stable users.
            if release.isPrerelease { return .upToDate(current: current) }
            if candidateIsNewer(release.version, than: current) {
                return .updateAvailable(current: current, release: release)
            }
            return .upToDate(current: current)
        }
    }
}
