// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelDownloadDTOTests.swift — Download request/response DTO types
///
/// Coverage: request validation, provider defaults, SSE event factories,
/// status response structure.

import Testing
import Foundation
@testable import ocoreai

@Suite("DownloadModelRequest Validation")
struct DownloadRequestValidationTests {
    @Test("valid request passes validation")
    func validRequest() throws {
        let request = DownloadModelRequest(model: "test-model")
        try request.validate()
    }

    @Test("empty model throws")
    func emptyModelThrows() {
        let request = DownloadModelRequest(model: "")
        #expect(throws: AppError.self) {
            try request.validate()
        }
    }

    @Test("valid provider hf passes")
    func providerHF() throws {
        let request = DownloadModelRequest(model: "test", provider: "hf")
        try request.validate()
    }

    @Test("valid provider mscope passes")
    func providerMscope() throws {
        let request = DownloadModelRequest(model: "test", provider: "mscope")
        try request.validate()
    }

    @Test("invalid provider throws")
    func invalidProviderThrows() {
        let request = DownloadModelRequest(model: "test", provider: "invalid")
        #expect(throws: AppError.self) {
            try request.validate()
        }
    }

    @Test("nil provider defaults to hf")
    func defaultProvider() {
        let request = DownloadModelRequest(model: "test", provider: nil)
        #expect(request.effectiveProvider == "hf")
    }

    @Test("provider is correctly set")
    func providerIsSet() {
        let request = DownloadModelRequest(model: "test", provider: "mscope")
        #expect(request.effectiveProvider == "mscope")
    }

    @Test("revision and useLatest preserved")
    func revisionPreserved() {
        let request = DownloadModelRequest(model: "test", revision: "v1.0", useLatest: true)
        #expect(request.revision == "v1.0")
        #expect(request.useLatest == true)
        #expect(request.model == "test")
    }
}

@Suite("DownloadSSEEvent Factories")
struct DownloadSSEEventTests {
    @Test("progress event has correct type")
    func progressEvent() {
        let event = DownloadSSEEvent.progress("dl-1", percentage: 50, totalBytes: 1000, transferredBytes: 500, eta: 10)
        #expect(event.eventType == "progress")
        #expect(event.percentage == 50)
        #expect(event.totalBytes == 1000)
        #expect(event.transferredBytes == 500)
    }

    @Test("completed event has correct type")
    func completedEvent() {
        let event = DownloadSSEEvent.completed("dl-1", cacheDir: "/path/to/cache")
        #expect(event.eventType == "completed")
        #expect(event.percentage == 100)
        #expect(event.cacheDir == "/path/to/cache")
        #expect(event.errorMessage == nil)
    }

    @Test("error event has correct type")
    func errorEvent() {
        let event = DownloadSSEEvent.error("dl-1", message: "Connection failed")
        #expect(event.eventType == "error")
        #expect(event.errorMessage == "Connection failed")
        #expect(event.percentage == nil)
    }

    @Test("SSE event round-trips through JSON")
    func sseCodable() throws {
        let event = DownloadSSEEvent.progress("dl-1", percentage: 75, totalBytes: 2000, transferredBytes: 1500, eta: 5)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(DownloadSSEEvent.self, from: data)
        #expect(decoded.eventType == event.eventType)
        #expect(decoded.percentage == event.percentage)
        #expect(decoded.downloadId == event.downloadId)
    }
}

@Suite("DownloadStatusResponse")
struct DownloadStatusResponseTests {
    @Test("downloading status")
    func downloading() {
        let response = DownloadStatusResponse(
            downloadId: "dl-1",
            status: "downloading",
            percentage: 50,
            cacheDir: nil,
            errorMessage: nil
        )
        #expect(response.status == "downloading")
        #expect(response.percentage == 50)
    }

    @Test("completed status")
    func completed() {
        let response = DownloadStatusResponse(
            downloadId: "dl-1",
            status: "completed",
            percentage: 100,
            cacheDir: "/cache/model",
            errorMessage: nil
        )
        #expect(response.status == "completed")
        #expect(response.cacheDir == "/cache/model")
    }

    @Test("error status")
    func errorStatus() {
        let response = DownloadStatusResponse(
            downloadId: "dl-1",
            status: "error",
            percentage: 30,
            cacheDir: nil,
            errorMessage: "Network timeout"
        )
        #expect(response.status == "error")
        #expect(response.errorMessage == "Network timeout")
    }

    @Test("status response round-trips through JSON")
    func statusCodable() throws {
        let response = DownloadStatusResponse(
            downloadId: "dl-1",
            status: "downloading",
            percentage: 75,
            cacheDir: nil,
            errorMessage: nil
        )
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(DownloadStatusResponse.self, from: data)
        #expect(decoded.downloadId == response.downloadId)
        #expect(decoded.status == response.status)
        #expect(decoded.percentage == response.percentage)
    }
}
