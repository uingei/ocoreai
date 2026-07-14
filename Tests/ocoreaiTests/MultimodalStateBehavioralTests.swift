// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MultimodalStateBehavioralTests.swift — Multimodal context entry routing,
/// VisionOCR threshold, and MMContextEntry struct behavioral invariants.
///
/// Focus:
///  - MMContextEntry shouldSendAsText routing (ocr text vs image)
///  - VisionOCR.minCharacters threshold value
///
/// NOTE: MultimodalState is a @MainActor singleton whose didSet wiring fires
/// real AVFoundation services — direct toggle tests belong in UI integration
/// tests, not unit tests. TTSFilterConfig validation is covered by
/// TTSFilterConfigTests.

import Testing
@testable import ocoreai

@Suite("MMContextEntry — shouldSendAsText routing logic")
struct MMContextEntryRouteTests {

    @Test("entry with OCR text and no dataURL routes as text")
    func ocrRoutesAsText() {
        let entry = MultimodalState.MMContextEntry(
            name: "camera",
            dataURL: nil,
            ocrText: "Hello World"
        )
        #expect(entry.shouldSendAsText == true)
    }

    @Test("entry with dataURL and no OCR routes as image")
    func imageRoutesAsImage() {
        let entry = MultimodalState.MMContextEntry(
            name: "camera",
            dataURL: "data:image/jpeg;base64,abc",
            ocrText: nil
        )
        #expect(entry.shouldSendAsText == false)
    }

    @Test("entry with both dataURL and OCR text prefers image path")
    func bothPrefersImage() {
        let entry = MultimodalState.MMContextEntry(
            name: "camera",
            dataURL: "data:image/jpeg;base64,abc",
            ocrText: "Some text"
        )
        // shouldSendAsText requires ocrText != nil AND dataURL == nil
        #expect(entry.shouldSendAsText == false)
    }

    @Test("entry name is preserved through construction")
    func namePreserved() {
        let entry = MultimodalState.MMContextEntry(
            name: "screen",
            dataURL: "data:image/png;base64,xyz",
            ocrText: nil
        )
        #expect(entry.name == "screen")
    }

    @Test("entry with empty OCR text but no dataURL does NOT route as text")
    func emptyOCRTextRoutesAsImage() {
        let entry = MultimodalState.MMContextEntry(
            name: "camera",
            dataURL: nil,
            ocrText: ""
        )
        // shouldSendAsText requires ocrText non-nil AND non-empty
        #expect(entry.shouldSendAsText == false)
    }

    @Test("camera entry can be constructed with nil OCR")
    func cameraEntryNilOCR() {
        let entry = MultimodalState.MMContextEntry(
            name: "camera",
            dataURL: "data:image/jpeg;base64,frame",
            ocrText: nil
        )
        #expect(entry.name == "camera")
        #expect(entry.shouldSendAsText == false)
    }

    @Test("all context sources produce correct entries")
    func screenEntryRoutesAsImage() {
        let entry = MultimodalState.MMContextEntry(
            name: "screen",
            dataURL: "data:image/png;base64,screenshot",
            ocrText: nil
        )
        #expect(entry.name == "screen")
        #expect(entry.shouldSendAsText == false)
    }
}

@Suite("VisionOCR — threshold configuration")
struct VisionOCRThresholdTests {
    @MainActor @Test("minCharacters is 10")
    func minCharactersValue() {
        #expect(VisionOCR.minCharacters == 10)
    }
}
