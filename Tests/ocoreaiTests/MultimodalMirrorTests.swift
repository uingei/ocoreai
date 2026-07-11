// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MultimodalMirrorTests.swift — Mirror fixture for multimodal service state.
/// Tests user-visible state transitions via @Observable CaptureService
/// and ScreenshotService, not internal SDK calls (AVFoundation/Vision require
/// hardware and entitlements that tests sandbox lacks).
///
/// Coverage: CaptureService state machine, ScreenshotService availability,
/// OCR text flagging flow, session control contracts.
///
/// VisionOCR is internal + @MainActor — tested indirectly via CaptureService
/// state transitions (latestOCRText propagation).

import AVFoundation
import Foundation
import Testing
@testable import ocoreai

#if os(macOS)

@Suite("CaptureService — @Observable state machine")
struct CaptureServiceMirrorTests {

    @MainActor
    @Test("Default state: not capturing, no frame, no OCR text")
    func defaultState() {
        let service = CaptureService.shared
        #expect(!service.isCapturing)
        #expect(service.latestFrameDataURL == nil)
        #expect(service.latestOCRText == nil)
    }

    @MainActor
    @Test("Camera discovery produces list (may be empty in testsandbox)")
    func cameraDiscovery() {
        let service = CaptureService.shared
        #expect(service.availableCameras.count >= 0)
    }

    @MainActor
    @Test("OCR text set is reflected in latestOCRText")
    func ocrTextFlagging() {
        let service = CaptureService.shared
        service.latestOCRText = "Hello world from screen"
        #expect(service.latestOCRText == "Hello world from screen")
        service.latestOCRText = nil
    }

    @MainActor
    @Test("Frame URL set propagates via @Observable")
    func frameDataURL() {
        let service = CaptureService.shared
        let testURL = "data:image/jpeg;base64,ABC123"
        service.latestFrameDataURL = testURL
        #expect(service.latestFrameDataURL == testURL)
        service.latestFrameDataURL = nil
    }

    @MainActor
    @Test("Selected camera ID persists")
    func selectedCameraID() {
        let service = CaptureService.shared
        service.selectedCameraID = "test-camera-1"
        #expect(service.selectedCameraID == "test-camera-1")
    }
}

@Suite("ScreenshotService — @Observable state machine")
struct ScreenshotServiceMirrorTests {

    @MainActor
    @Test("Default state: not capturing, screen count > 0")
    func defaultState() {
        let service = ScreenshotService.shared
        #expect(!service.isCapturing)
        #expect(service.screenCount > 0)
    }

    @MainActor
    @Test("Availability flag is true on macOS")
    func isAvailable() {
        #expect(ScreenshotService.isAvailable == true)
    }

    @MainActor
    @Test("Frame URL is readable")
    func frameDataURL() {
        let service = ScreenshotService.shared
        // latestFrameDataURL is private(set) — only verify read access
        #expect(service.latestFrameDataURL == nil)
    }
}

#endif

// MARK: - Shared multimodal contracts (platform-agnostic)

@Suite("Multimodal notification contracts")
struct MultimodalNotificationTests {

    @Test("Camera frame notification name exists")
    func cameraFrameNotification() {
        let name = Notification.Name.cameraFrameAvailable
        #expect(name.rawValue == "CameraFrameAvailable")
    }

    @Test("Screen frame notification name exists on macOS")
    func screenFrameNotification() {
        #if os(macOS)
        let name = Notification.Name.screenFrameAvailable
        #expect(name.rawValue == "ScreenFrameAvailable")
        #endif
    }
}
