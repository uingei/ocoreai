// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// FileDiffTests — pins the inline-diff core behind the change-review UI.
// The review card is the user's ground truth for "what did the agent
// change"; these tests pin that ground truth: exact LCS line classification,
// honest counts, elision that never hides a changed line, and the size
// guard that keeps the render bounded. Formatting discipline: bind to `let`
// — swift-format 603 vs `main` wrap long #expect args differently.
import Testing

@testable import ocoreai

struct FileDiffTests {

    // MARK: - LCS line classification

    @Test func middleInsertionIsClassifiedExactly() {
        let old = "a\nb\nd"
        let new = "a\nb\nc\nd"
        let d = FileDiff.between(path: "f.txt", old: old, new: new)
        func isAdded(_ l: FileDiff.Line, _ t: String) -> Bool {
            if case .added(let x) = l { return x == t } else { return false }
        }
        func isRemoved(_ l: FileDiff.Line) -> Bool {
            if case .removed = l { return true } else { return false }
        }
        let added = d.lines.filter { isAdded($0, "c") }
        let removed = d.lines.filter(isRemoved)
        #expect(added.count == 1)
        #expect(removed.count == 0)
        #expect(d.addedCount == 1)
        #expect(d.removedCount == 0)
    }

    @Test func replacementProducesPairedRemoveAdd() {
        let old = "keep\nold line\nkeep2"
        let new = "keep\nnew line\nkeep2"
        let d = FileDiff.between(path: "f.txt", old: old, new: new)
        #expect(d.removedCount == 1)
        #expect(d.addedCount == 1)
        func has(_ l: FileDiff.Line, _ side: String, _ t: String) -> Bool {
            switch (side, l) {
            case ("old", .removed(let x)): return x == t
            case ("new", .added(let x)): return x == t
            default: return false
            }
        }
        let hasOld = d.lines.contains { has($0, "old", "old line") }
        let hasNew = d.lines.contains { has($0, "new", "new line") }
        #expect(hasOld)
        #expect(hasNew)
    }

    @Test func identicalFilesHaveZeroCounts() {
        let text = "one\ntwo\nthree"
        let d = FileDiff.between(path: "f.txt", old: text, new: text)
        #expect(d.addedCount == 0)
        #expect(d.removedCount == 0)
        func isUnchangedOrElided(_ l: FileDiff.Line) -> Bool {
            switch l {
            case .context, .elided: return true
            case .added, .removed: return false
            }
        }
        let allUnchanged = d.lines.allSatisfy(isUnchangedOrElided)
        #expect(allUnchanged)
    }

    // MARK: - Elision keeps every change visible

    @Test func collapseNeverHidesAChangedLine() {
        // 200 unchanged lines, two far-apart edits ON THE OLD SIDE ONLY
        // (new side = clean) so the diff is pure removals.
        var a: [String] = (0 ..< 200).map { "line \($0)" }
        let b = a
        a[10] = "EDITED top"
        a[190] = "EDITED bottom"
        let old = a.joined(separator: "\n")
        let new = b.joined(separator: "\n")
        let d = FileDiff.between(path: "big.txt", old: old, new: new)
        // LCS pairs each edit as 1 removal + 1 addition; counts are over
        // the FULL diff, not the collapsed view.
        #expect(d.addedCount == 2)
        #expect(d.removedCount == 2)
        func editedRemoved(_ l: FileDiff.Line) -> Bool {
            if case .removed(let t) = l { return t.starts(with: "EDITED") } else { return false }
        }
        let visibleEdits = d.lines.filter(editedRemoved).count
        #expect(visibleEdits == 2)
        // Elision markers exist (200 lines, ±3 context — most must elide).
        func isElided(_ l: FileDiff.Line) -> Bool {
            if case .elided = l { return true } else { return false }
        }
        let elided = d.lines.filter(isElided).count
        #expect(elided >= 1)
        // The rendered body stays compact.
        #expect(d.lines.count < 40)
    }

    // MARK: - Creation / deletion

    @Test func createdIsAllAdded() {
        let d = FileDiff.created(path: "n.txt", content: "x\ny\nz")
        #expect(d.addedCount == 3)
        #expect(d.removedCount == 0)
        func isAdded(_ l: FileDiff.Line) -> Bool {
            if case .added = l { return true } else { return false }
        }
        let allAdded = d.lines.allSatisfy(isAdded)
        #expect(allAdded)
    }

    @Test func deletedIsAllRemoved() {
        let d = FileDiff.deleted(path: "n.txt", content: "x\ny")
        #expect(d.addedCount == 0)
        #expect(d.removedCount == 2)
    }

    // MARK: - Size guard stays bounded (no quadratic hang)

    @Test func oversizedInputFallsBackCoarsely() {
        let big = (0 ..< 4001).map { "l\($0)" }.joined(separator: "\n")
        let small = "q\nr"
        let d = FileDiff.between(path: "huge.txt", old: big, new: small, maxLines: 4000)
        // Coarse fallback: whole old side removed, whole new side added.
        #expect(d.removedCount == 4001)
        #expect(d.addedCount == 2)
    }

    // MARK: - Review-card routing

    @Test func reviewableRoutingMatchesBuiltInToolArgs() {
        let edit = ToolCallPart(
            callId: "1", name: "edit_file",
            arguments: ["path": "/tmp/a", "oldString": "x", "newString": "y"])
        #expect(FileDiffCard.isReviewable(edit))
        // Missing strings during argument streaming → NOT reviewable yet.
        let streaming = ToolCallPart(callId: "2", name: "edit_file", arguments: ["path": "/tmp/a"])
        #expect(!FileDiffCard.isReviewable(streaming))
        let read = ToolCallPart(callId: "3", name: "read_file", arguments: ["path": "/tmp/a"])
        #expect(!FileDiffCard.isReviewable(read))
        let write = ToolCallPart(
            callId: "4", name: "write_file", arguments: ["path": "/tmp/b", "content": "hi"])
        #expect(FileDiffCard.isReviewable(write))
    }
}
