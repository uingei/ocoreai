// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! UIFocusDisciplineTests — the UI keyboard contract, measured.
//!
//! `Sources/ocoreai/UI/AGENTS.md` states it in prose: "⌘ coverage and a sane
//! focus order for primary actions, `Cmd+,` grouped Settings" and "One cancel
//! gesture, exactly one effect. Keyboard ownership follows focus." Prose
//! without a reader is how a second focus site or a stray `.defaultAction`
//! ships silently — this suite is the reader. Scan-based, per the Testing
//! Quality rules: the repo root is found by search, every scan floors its own
//! hit count, and the asserted values are the exact ones measured in the
//! sources when this file was written, so a scan that stops matching fails
//! instead of passing vacuously.
//!
//! Deleting the dead `OcoreaiTextInput` (a second `@FocusState` with zero
//! callers) was a precondition of the single-focus-site assertion below.

import Foundation
import Testing

@testable import ocoreai

@Suite("UI focus discipline — one composer, one monitor, one effect")
struct UIFocusDisciplineTests {

    // MARK: - Scan plumbing

    private enum ScanError: Error {
        case rootNotFound
    }

    /// Walk up from this file until `Package.swift` sits next to `Sources/`.
    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let marker = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: marker.path),
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("Sources").path)
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw ScanError.rootNotFound
    }

    private static func read(_ relative: String) throws -> String {
        let root = try repoRoot()
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ScanError.rootNotFound
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// All `.swift` files under `Sources/`, deterministic order. Paths stay
    /// relative to the repo root (they keep the `Sources/` prefix that `read`
    /// resolves against).
    private static func swiftFiles() throws -> [String] {
        let root = try repoRoot()
        let sources = root.appendingPathComponent("Sources")
        var found: [String] = []
        guard
            let enumerator = FileManager.default.enumerator(
                at: sources, includingPropertiesForKeys: nil)
        else {
            throw ScanError.rootNotFound
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            found.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
        }
        found.sort()
        return found
    }

    private static func filesContaining(_ pattern: String) throws -> [String] {
        var hits: [String] = []
        for path in try swiftFiles() {
            if try read(path).contains(pattern) {
                hits.append(path)
            }
        }
        return hits
    }

    // MARK: - Keyboard ownership

    @Test("the composer is the only keyboard-owning text field in the app")
    func singleComposerOwnsTheKeyboard() throws {
        let files = try Self.swiftFiles()
        #expect(files.count >= 250, "scan walked the tree (floor 250, measured 298)")
        let focused = try Self.filesContaining(".focused($")
        #expect(
            focused == ["Sources/ocoreai/UI/Views/ChatView.swift"],
            "exactly one .focusable( binding: the composer; a second text field is an owner call")
        let focusState = try Self.filesContaining("@FocusState")
        #expect(
            focusState == ["Sources/ocoreai/UI/Views/ChatView.swift"],
            "one @FocusState, same file as the .focused( site")
    }

    @Test("one local key monitor owns the window-level keys; no global monitor")
    func oneRawKeyMonitor() throws {
        let local = try Self.filesContaining("NSEvent.addLocalMonitorForEvents")
        #expect(
            local == ["Sources/ocoreai/UI/Views/ChatView.swift"],
            "one local key monitor, in the chat surface that needs window-level keys")
        let global = try Self.filesContaining("addGlobalMonitorForEvents")
        #expect(global.isEmpty, "a global monitor reads keys in other apps — never")
    }

    // MARK: - ⌘ coverage for primary actions

    @Test("primary actions have their ⌘ coverage in the surfaces that own them")
    func primaryActionCommandCoverage() throws {
        let chat = try Self.read("Sources/ocoreai/UI/Views/ChatView.swift")
        #expect(
            chat.contains(".keyboardShortcut(.return, modifiers: .command)"),
            "resend is ⌘↵ on the edit bar")
        #expect(
            chat.contains("event.characters == \"\\r\""),
            "⌘↵ sends even when the text field does not have focus")
        #expect(chat.contains("showMultimodal.toggle()"), "⌥⌘M toggles the multimodal panel")

        let app = try Self.read("Sources/ocoreai/UI/Application.swift")
        #expect(
            app.contains("CommandGroup(replacing: .appSettings)"),
            "⌘, stays the standard Settings group")
        #expect(
            app.contains("CommandGroup(replacing: .newItem) {}"),
            "⌘N stays disabled — this app has no documents")
        #expect(
            app.contains(".keyboardShortcut(\"v\", modifiers: [.command, .shift])"),
            "⇧⌘V is the guaranteed paste route (the field editor claims ⌘V)")
        #expect(app.contains(".keyboardShortcut(\"z\", modifiers: .command)"), "⌘Z undo")
    }

    @Test("Esc interrupts only while streaming and shares the one cancel effect")
    func escInterruptSharesTheCancelEffect() throws {
        let chat = try Self.read("Sources/ocoreai/UI/Views/ChatView.swift")
        let pattern = #"event.keyCode == 53 && isStreaming\s*\{\s*stopStreaming\(\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: chat.utf16.count)
        #expect(
            regex.firstMatch(in: chat, range: range) != nil,
            "Esc → stopStreaming() under the isStreaming guard, so an idle Esc stays with the editor"
        )
    }

    @Test("the composer never claims the bare Return")
    func composerNeverClaimsBareReturn() throws {
        let chat = try Self.read("Sources/ocoreai/UI/Views/ChatView.swift")
        #expect(
            !chat.contains(".keyboardShortcut(.defaultAction)"),
            "a default button claims bare ↵ for the whole window — the composer must stay typeable")
        let defaults = try Self.filesContaining(".keyboardShortcut(.defaultAction)")
        #expect(
            defaults == ["Sources/ocoreai/UI/Views/ProjectsView.swift"],
            "only the modal sheet's add button is a default action")
    }

    // MARK: - The numbering rule

    /// `selectedTab = .x` … `.keyboardShortcut("N")` pairs, in declaration order.
    /// A shortcut behind `//` is not a shortcut, so the shape is anchored to the line:
    /// assignment, the closing brace, then the key — whitespace only before each.
    private static func numberedTabShortcuts(in app: String) throws -> [String] {
        let pattern =
            #"[ \t]*selectedTab = \.([A-Za-z_]+)\n[ \t]*\}[ \t]*\n[ \t]*\.keyboardShortcut\("(\d)"\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: app.utf16.count)
        var pairs: [String] = []
        for match in regex.matches(in: app, range: range) {
            guard
                let tabRange = Range(match.range(at: 1), in: app),
                let keyRange = Range(match.range(at: 2), in: app)
            else { continue }
            pairs.append(String(app[tabRange]) + ":" + String(app[keyRange]))
        }
        return pairs
    }

    // The expectation is derived from AppTab's own sidebar groups, which is what
    // `sidebarSections` renders — not from a literal copied out of the menu. Drift
    // on either side goes red: reorder a group, or renumber a button, same failure.
    @Test("⌘1–⌘8 number every tab but Settings, in the order the sidebar renders them")
    func tabNumberingFollowsTheSidebar() throws {
        let sidebar = AppTab.serverGroup + AppTab.workflowGroup + AppTab.systemGroup
        #expect(
            Set(sidebar) == Set(AppTab.allCases) && sidebar.count == AppTab.allCases.count,
            "the three groups are the whole sidebar; a tab outside them would silently shorten it")
        // Settings is last and owns ⌘,, so the eight number keys are the other eight.
        let numbered = sidebar.filter { $0 != .settings }
        let expected = numbered.enumerated().map { "\($0.element.rawValue):\($0.offset + 1)" }
        #expect(expected.count >= 8, "eight numbered tabs (floor 8, measured 8)")

        let app = try Self.read("Sources/ocoreai/UI/Application.swift")
        #expect(
            try Self.numberedTabShortcuts(in: app) == expected,
            "⌘ numbers follow the sidebar order, contiguous from ⌘1")
    }

    // `CommandGroup(replacing: .appSettings)` deletes the system item, so the ⌘, it
    // carried is gone unless this file declares it — the guide's "Cmd+, grouped
    // Settings" duty needed a line that delivers it, and this is the line.
    @Test("⌘, for Settings is a declared shortcut, not just the name of the group")
    func settingsOwnsItsCommandKey() throws {
        let app = try Self.read("Sources/ocoreai/UI/Application.swift")
        let pattern =
            #"CommandGroup\(replacing: \.appSettings\)[\s\S]{0,400}?\n[ \t]*\.keyboardShortcut\(",", modifiers: \.command\)\n"#
        let regex = try NSRegularExpression(pattern: pattern)
        #expect(
            regex.firstMatch(
                in: app, range: NSRange(location: 0, length: app.utf16.count)) != nil,
            "the Settings button declares ⌘, itself")
    }
}
