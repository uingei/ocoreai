// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AppInfo — the single truth for the running app's identity.
///
/// First principles: every user-visible or machine-visible surface (About
/// section, Prometheus `ocoreai_build`, future auto-update checks) must
/// report the SAME version the artifact was actually built as. Hardcoded
/// literals shipped "1.0.0" while git tag v0.1.6 was on the wire — an
/// identity lie with two mouths (Settings UI + metrics dashboard).
///
/// The build pipeline (`scripts/build-app.sh:72`) injects
/// CFBundleShortVersionString from `git describe --tags`; dev builds
/// (SPM test host, no bundle plist) fall back honestly to "dev" — never
/// to a fake release number.
import Foundation

public enum AppInfo {
    /// CFBundleShortVersionString of the running bundle, e.g. "0.1.6".
    /// Non-bundled hosts (unit tests via SPM test runner) → "dev".
    public static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
