// oCoreAI — absorbed VLM config + image-preprocessor tests (unit-testable, no ANE).
// Upstream provenance (BSD-3-clause, Apple), coreai-models HEAD 5716935:
//   Bundle/LanguageConfig.swift (VisionConfig), Image/ImagePreprocessor.swift
// Exact-value assertions where math permits; image cases anchor on the
// zero-input offset (independent of the u8→float vDSP scale) and plane sizes.

import CoreGraphics
import Foundation
import Testing

@testable import ocoreai

private func vfmSolidCGImage(_ w: Int, _ h: Int, _ rgba: (CGFloat, CGFloat, CGFloat, CGFloat))
    -> CGImage
{
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: w * 4, space: cs,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: rgba.0, green: rgba.1, blue: rgba.2, alpha: rgba.3)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

@Suite("CoreAIVisionConfig")
struct CoreAIVisionConfigTests {
    @Test("VisionConfig decodes upstream wire shape (exact)")
    func decodeExact() throws {
        let json = """
            {"image_size":896,"patch_size":14,"image_token_count":280,"image_token_id":258878,\
            "image_mean":[0.485,0.456,0.406],"image_std":[0.229,0.224,0.225],\
            "rescale_factor":1.0,"image_strategy":"center_crop","include_image_info":true,\
            "max_video_frames":32,"tokens_per_frame":280}
            """
        let v = try JSONDecoder().decode(VisionConfig.self, from: Data(json.utf8))
        #expect(v.imageSize == 896)
        #expect(v.patchSize == 14)
        #expect(v.imageTokenCount == 280)
        #expect(v.imageTokenId == 258878)
        #expect(abs(v.imageMean[0] - 0.485) < 1e-9)
        #expect(abs(v.imageStd[1] - 0.224) < 1e-9)
        #expect(v.rescaleFactor == 1.0)
        #expect(v.imageStrategy == .centerCrop)
        #expect(v.imageStrategy.rawValue == "center_crop")
        #expect(v.includeImageInfo == true)
        #expect(v.supportsVideo == true)
        #expect(v.maxVideoFrames == 32)
        #expect(v.tokensPerFrame == 280)
    }

    @Test("VisionConfig omitted normalization falls back to CLIP (exact)")
    func clipDefaults() throws {
        let json = #"""
            {"image_size":336,"patch_size":14,"image_token_count":256,"image_token_id":0}
            """#
        let v = try JSONDecoder().decode(VisionConfig.self, from: Data(json.utf8))
        #expect(abs(v.imageMean[0] - 0.48145466) < 1e-9)
        #expect(abs(v.imageStd[0] - 0.26862954) < 1e-9)
        #expect(v.rescaleFactor == 1.0)
        #expect(v.imageStrategy == .stretch)
        #expect(v.includeImageInfo == false)
        #expect(v.supportsVideo == false)
        #expect(v.maxVideoFrames == nil)
        #expect(v.tokensPerFrame == nil)
    }

    @Test("Encoded VisionConfig round-trips (exact)")
    func roundTrip() throws {
        let v = VisionConfig(
            imageSize: 512, patchSize: 16, imageTokenCount: 1024,
            imageTokenId: 925, imageStrategy: .pad,
            maxVideoFrames: 8, tokensPerFrame: 1024)
        let d = try JSONDecoder().decode(
            VisionConfig.self,
            from: JSONEncoder().encode(v))
        #expect(d == v)
        #expect(d.imageStrategy == ImageStrategy.pad)
        #expect(d.imageStrategy.rawValue == "pad")
    }

    @Test("Engine glue: VisionConfig -> ImagePreprocessor exactly (upstream L324-331)")
    func glueToPreprocessor() {
        let vc = VisionConfig(
            imageSize: 896, patchSize: 14, imageTokenCount: 280,
            imageTokenId: 258878,
            imageMean: [0.485, 0.456, 0.406],
            imageStd: [0.229, 0.224, 0.225])
        // Verbatim glue from CoreAISequentialVLMEngine init (upstream L324-331)
        let pp = ImagePreprocessor(
            targetSize: CGSize(width: vc.imageSize, height: vc.imageSize),
            mean: (CGFloat(vc.imageMean[0]), CGFloat(vc.imageMean[1]), CGFloat(vc.imageMean[2])),
            std: (CGFloat(vc.imageStd[0]), CGFloat(vc.imageStd[1]), CGFloat(vc.imageStd[2])),
            rescaleFactor: CGFloat(vc.rescaleFactor))
        #expect(pp.targetSize.width == 896)
        #expect(pp.targetSize.height == 896)
        #expect(pp.mean.0 == 0.485)
        #expect(pp.mean.1 == 0.456)
        #expect(pp.mean.2 == 0.406)
        #expect(pp.std.0 == 0.229)
        #expect(pp.std.2 == 0.225)
        #expect(pp.rescaleFactor == 1.0)
    }

    #if canImport(CoreAI)
    @Test(
        "VLMModelConfig surfaces InferenceConfiguration via base (exact)",
        .disabled(
            "requires macOS 27 runtime; exercised in CI matrix"))
    @available(macOS 27.0, *)
    func vlmConfigSurfaces() {
        let base = InternalModelConfig(
            name: "vlm-test", vocabSize: 262244,
            maxContextLength: 8192, function: "llm")
        let vlm = VLMModelConfig(
            base: base,
            visionConfig: VisionConfig(
                imageSize: 896, patchSize: 14,
                imageTokenCount: 280, imageTokenId: 258878))
        let c: any InferenceConfiguration = vlm
        #expect(c.maxContextLength == 8192)
        #expect(c.prefillChunkSize == 512)
        #expect(c.chunkThreshold == 1024)
        #expect(vlm.eosTokenId == 0)
        #expect(vlm.visionConfig.imageSize == 896)
    }
    #endif
}

private let allStrategies: [ImageStrategy] = [.stretch, .centerCrop, .pad]

@Suite("CoreAIImagePreprocessor")
struct CoreAIImagePreprocessorTests {
    private static let standard = ImagePreprocessor(
        targetSize: CGSize(width: 2, height: 2),
        mean: (0.485, 0.456, 0.406),
        std: (0.229, 0.224, 0.225),
        rescaleFactor: 1.0)

    @Test("Preset anchors (exact)")
    func presets() {
        #expect(ImagePreprocessor.gemma3.targetSize.width == 896)
        #expect(ImagePreprocessor.gemma3.targetSize.height == 896)
        #expect(ImagePreprocessor.gemma3.mean.0 == 0.485)
        #expect(ImagePreprocessor.gemma3.std.2 == 0.225)
        #expect(ImagePreprocessor.gemma3.rescaleFactor == 1.0)
        #expect(ImagePreprocessor.clip.targetSize.width == 336)
        #expect(ImagePreprocessor.clip.targetSize.height == 336)
    }

    @Test(arguments: allStrategies)
    func strategyCodable(_ s: ImageStrategy) throws {
        let d = try JSONDecoder().decode(
            ImageStrategy.self,
            from: JSONEncoder().encode(s))
        #expect(d == s)
    }

    @Test("NHWC output: RGBA layout, size = W*H*16, alpha plane = 0")
    func outputShape() throws {
        let (data, w, h) = try Self.standard.preprocess(
            cgImage: vfmSolidCGImage(4, 4, (0.5, 0.5, 0.5, 1)))
        #expect(w == 2)
        #expect(h == 2)
        #expect(data.count == 2 * 2 * 4 * 4)  // W*H*(RGBA*4B) = 64 bytes
        let f = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for i in 0 ..< 4 {
            #expect(f[i * 4 + 3] == 0)
        }
        #expect(f.count == 2 * 2 * 4)  // 16 floats
    }

    @Test("Zero-input RGB offset is exact per channel (scale-invariant)")
    func blackImageExactOffset() throws {
        let pp = Self.standard
        let (data, w, h) = try pp.preprocess(cgImage: vfmSolidCGImage(2, 2, (0, 0, 0, 1)))
        #expect(w == 2 && h == 2)
        #expect(data.count == 4 * 16)
        let f = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let er = Float(-0.485 / 0.229)
        let eg = Float(-0.456 / 0.224)
        let eb = Float(-0.406 / 0.225)
        for i in 0 ..< 4 {
            #expect(abs(f[i * 4] - er) < 1e-5)
            #expect(abs(f[i * 4 + 1] - eg) < 1e-5)
            #expect(abs(f[i * 4 + 2] - eb) < 1e-5)
            #expect(f[i * 4 + 3] == 0)
        }
    }

    @Test("CHW layout: 3*H*W, red input puts channel-R plane > G/B planes")
    func chwRed() throws {
        let pp = Self.standard
        let f = try pp.preprocessCHW(cgImage: vfmSolidCGImage(8, 8, (1, 0, 0, 1)))
        #expect(f.count == 3 * 4)
        #expect(f[0] > f[4])
        #expect(f[0] > f[8])
    }

    @Test("CHW identity: identity mean/std yields zero offset (scale-invariant exact)")
    func chwIdentity() throws {
        let pp = ImagePreprocessor(
            targetSize: CGSize(width: 2, height: 2),
            mean: (0, 0, 0), std: (1, 1, 1), rescaleFactor: 1.0)
        let f = try pp.preprocessCHW(cgImage: vfmSolidCGImage(4, 4, (0, 0, 0, 1)))
        #expect(f.count == 12)
        for x in f { #expect(x == 0) }
    }

    @Test("Strategy dispatch: stretch / centerCrop / pad each produce 3*H*W planes")
    func strategyDispatch() throws {
        let pp = Self.standard
        let img = vfmSolidCGImage(8, 4, (0.5, 0.5, 0.5, 1))
        #expect(try pp.preprocessCHW(cgImage: img, strategy: .stretch).count == 12)
        #expect(try pp.preprocessCHW(cgImage: img, strategy: .centerCrop).count == 12)
        #expect(try pp.preprocessCHW(cgImage: img, strategy: .pad).count == 12)
    }

    @Test("preprocess(imageURL:) throws loadFailed on a non-image file")
    func loadFailed() {
        let pp = Self.standard
        #expect(throws: ImagePreprocessorError.self) {
            try pp.preprocess(imageURL: URL(fileURLWithPath: "/tmp/ocoreai-no-such-image.xyz"))
        }
    }

    @Test("ImagePreprocessorError descriptions (exact)")
    func errorDescriptions() {
        let url = URL(fileURLWithPath: "/tmp/a.png")
        #expect(
            ImagePreprocessorError.loadFailed(url).errorDescription
                == "Failed to load image from: /tmp/a.png")
        #expect(
            ImagePreprocessorError.renderFailed.errorDescription
                == "Failed to render preprocessed image")
    }
}
