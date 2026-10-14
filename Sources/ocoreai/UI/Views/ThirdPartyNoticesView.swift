// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Third-party notices panel (Settings -> About -> Third-Party Notices).
///
/// Why this exists in the GUI and not only in the DMG: BSD-3 clause 2 and
/// Apache-2.0 section 4 require the license texts to travel with the product,
/// and "right-click the app, show package contents" is not a user-facing
/// answer. Every text on this screen is selectable, and each dependency's full
/// text is read from the bundle only when its row is opened.
///
/// When the running binary carries no notices (a bare `swift build` product),
/// the panel says so plainly instead of showing an empty list.

import SwiftUI

struct ThirdPartyNoticesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(StringKey.thirdPartyNotices.l)
                    .font(.title3.bold())
                Spacer()
                Button(StringKey.cancelButton.l) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let manifest = ThirdPartyNotices.manifest {
                        intro
                        appleSection(manifest.apple)
                        dependencySection(manifest.dependencies)
                        referenceSection
                    } else {
                        Text(StringKey.thirdPartyNoticesUnavailable.l)
                            .font(.ocoreaiText(13))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .accessibilityLabel(StringKey.thirdPartyNotices.l)
    }

    private var intro: some View {
        Text(StringKey.thirdPartyNoticesIntro.l)
            .font(.ocoreaiText(12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func appleSection(_ apple: ThirdPartyNoticesManifest.Apple) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(StringKey.thirdPartyNoticesApple.l)
                .font(.ocoreaiText(13, weight: .semibold))
            Text(StringKey.thirdPartyNoticesAppleDetail.l)
                .font(.ocoreaiText(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup {
                Text(ThirdPartyNotices.appleLicenseText ?? StringKey.thirdPartyNoticesUnavailable.l)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("\(apple.upstream) · \(apple.license)")
                    .font(.ocoreaiText(12))
            }
        }
    }

    private func dependencySection(_ dependencies: [ThirdPartyLicenseEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(StringKey.thirdPartyNoticesDependencies.l)
                .font(.ocoreaiText(13, weight: .semibold))
            Text(StringKey.thirdPartyNoticesDependenciesDetail.l)
                .font(.ocoreaiText(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(dependencies) { entry in
                ThirdPartyLicenseRow(entry: entry)
            }
        }
    }

    private var referenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(StringKey.thirdPartyNoticesCodex.l)
                .font(.ocoreaiText(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(StringKey.thirdPartyNoticesFrameworks.l)
                .font(.ocoreaiText(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// One dependency row: identity on the surface, full text behind the disclosure.
private struct ThirdPartyLicenseRow: View {
    let entry: ThirdPartyLicenseEntry
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(
                ThirdPartyNotices.licenseText(for: entry)
                    ?? StringKey.thirdPartyNoticesUnavailable.l
            )
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                Text(entry.name)
                    .font(.ocoreaiText(12))
                Spacer(minLength: 8)
                Text(entry.license)
                    .font(.ocoreaiText(11))
                    .foregroundStyle(.secondary)
                Text(entry.pin)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
