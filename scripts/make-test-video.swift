// make-test-video.swift — render a solid-colour .mp4 with AVFoundation, for the live
// video-honesty probe (scripts/probes/08-video-honesty.sh).
//
// Why a generator instead of a fixture in git: a committed binary clip is a blob nobody can
// review, and the clip must be re-renderable on any Mac to prove the probe still works
// against THIS host's AVFoundation/VideoToolbox stack. Solid colour is deliberate: it makes
// "did the model actually see the frames" answerable in one word, and rendering two
// different colours lets the probe tell seeing from guessing.
//
// Usage: swift scripts/make-test-video.swift <out.mp4> [red|green|blue] [seconds] [fps]
//
// Self-verifies before exiting 0: re-opens the file with AVURLAsset and reports track count,
// duration, pixel size and byte size, so a probe can never count a broken clip as evidence.
// Frames are appended through AVAssetWriterInputPixelBufferAdaptor — the current, non-deprecated path.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-test-video: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("usage: make-test-video <out.mp4> [red|green|blue] [seconds] [fps]")
}
let outURL = URL(fileURLWithPath: args[1])
let colourName = args.count > 2 ? args[2].lowercased() : "red"
let seconds = args.count > 3 ? (Double(args[3]) ?? 2.0) : 2.0
let fps = args.count > 4 ? max(1, Int(args[4]) ?? 15) : 15

// Memory layout is BGRA: [B, G, R, A].
let pattern: UInt32
switch colourName {
case "red": pattern = 0xFFFF_0000
case "green": pattern = 0xFF00_FF00
case "blue": pattern = 0xFF00_00FF
default: fail("unsupported colour \(colourName) (red|green|blue)")
}

let width = 128
let height = 128
let timescale = 600

var pixelBuffer: CVPixelBuffer?
let createStatus = CVPixelBufferCreate(
    kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
    [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        // No IOSurface request: an IOSurface-backed buffer fails to allocate in a
        // restricted session (CVPixelBufferCreate -> kCVReturnAllocationFailed, -6662,
        // measured 10-16). A plain CPU buffer encodes fine through the adaptor.
    ] as CFDictionary,
    &pixelBuffer)
guard createStatus == kCVReturnSuccess, let buffer = pixelBuffer else {
    fail("CVPixelBufferCreate failed (\(createStatus))")
}

// A stale file at the destination makes AVAssetWriter fail with -11823 "Cannot Save /
// requested file name is already in use", so clear it first and keep re-runs repeatable.
try? FileManager.default.removeItem(at: outURL)

let writer: AVAssetWriter
do {
    writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
} catch {
    fail("cannot create AVAssetWriter at \(outURL.path): \(error)")
}

let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
input.expectsMediaDataInRealTime = false
guard writer.canAdd(input) else { fail("writer cannot accept a H.264 \(width)x\(height) input") }
writer.add(input)

// macOS 26 spelling: a class factory taking sourcePixelBufferAttributes, non-failable.
// (AVFoundation reports failures through AVAssetWriter.status/.error, not on the input.)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])

writer.startWriting()
guard writer.status == .writing else { fail("startWriting: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)

CVPixelBufferLockBaseAddress(buffer, [])
defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
guard let base = CVPixelBufferGetBaseAddress(buffer) else { fail("no pixel buffer base address") }
let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
let rows = CVPixelBufferGetHeight(buffer)
let strideInWords = rowBytes / MemoryLayout<UInt32>.size
let cells = base.bindMemory(to: UInt32.self, capacity: strideInWords * rows)
for row in 0 ..< rows {
    for column in 0 ..< width {
        cells[row * strideInWords + column] = pattern
    }
}

var appended = 0
for index in 0 ..< max(1, Int(seconds * Double(fps))) {
    let pts = CMTime(value: CMTimeValue(index * timescale / fps), timescale: CMTimeScale(timescale))
    while !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if adaptor.append(buffer, withPresentationTime: pts) {
        appended += 1
    } else {
        fail("adaptor.append failed at frame \(index): writer.status=\(writer.status.rawValue) \(String(describing: writer.error))")
    }
}
input.markAsFinished()

let finishSemaphore = DispatchSemaphore(value: 0)
writer.finishWriting { finishSemaphore.signal() }
finishSemaphore.wait()
guard writer.status == .completed else {
    fail("finishWriting: status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
}

// ── self-verify: reopen and report what a consumer would see ──────────────────
// Checked through macOS 13+ load(...) so the clip the probe relies on is verified via the
// API path AVFoundation's current readers use.
let verifySemaphore = DispatchSemaphore(value: 0)
nonisolated(unsafe) var verifyFailure: String?
nonisolated(unsafe) var reportLine: String?
Task {
    do {
        let asset = AVURLAsset(url: outURL)
        let (tracks, clipDuration) = try await asset.load(.tracks, .duration)
        guard !tracks.isEmpty else {
            verifyFailure = "wrote \(outURL.path) but AVURLAsset reports zero tracks"
            verifySemaphore.signal()
            return
        }
        let clipSeconds = CMTimeGetSeconds(clipDuration)
        guard clipSeconds > 0, clipSeconds.isFinite else {
            verifyFailure = "reopened asset has zero duration"
            verifySemaphore.signal()
            return
        }
        let size = try await tracks[0].load(.naturalSize)
        let attributes = try? FileManager.default.attributesOfItem(atPath: outURL.path)
        let bytes = (attributes?[.size] as? Int) ?? 0
        guard bytes > 0 else {
            verifyFailure = "output file is empty"
            verifySemaphore.signal()
            return
        }
        reportLine =
            "wrote \(outURL.path) colour=\(colourName) bytes=\(bytes) frames=\(appended) duration=\(String(format: "%.3f", clipSeconds)) size=\(Int(size.width))x\(Int(size.height))"
    } catch {
        verifyFailure = "self-verify failed: \(error)"
    }
    verifySemaphore.signal()
}
verifySemaphore.wait()
if let failure = verifyFailure { fail(failure) }
print(reportLine ?? "wrote \(outURL.path) frames=\(appended)")
