// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Testing

@testable import ocoreai

@Suite("Tiled 3D VAE decode (Wan 2.1)")
struct Wan21TiledDecodeTests {
    @Test("computeTileStarts returns a single tile when size >= total")
    func singleTile() {
        #expect(computeTileStarts(totalSize: 30, tileSize: 32, overlap: 4) == [0])
    }

    @Test("computeTileStarts covers full extent and respects stride")
    func fullCoverage() {
        let starts = computeTileStarts(totalSize: 60, tileSize: 32, overlap: 4)
        #expect(starts.count >= 2)
        #expect(starts.last! + 32 >= 60)

        let starts2 = computeTileStarts(totalSize: 100, tileSize: 32, overlap: 4)
        for i in 1 ..< starts2.count - 1 {
            #expect(starts2[i] - starts2[i - 1] == 28)  // stride = 32 - 4
        }
    }

    @Test("blendWeight returns 1.0 for first tile and ramps linearly in overlap region")
    func blendFirstAndRamp() {
        #expect(blendWeight(position: 0, overlap: 4, isFirst: true) == 1.0)
        #expect(blendWeight(position: 3, overlap: 4, isFirst: true) == 1.0)

        #expect(blendWeight(position: 0, overlap: 4, isFirst: false) == 0.0)
        #expect(abs(blendWeight(position: 2, overlap: 4, isFirst: false) - 0.5) < 1e-6)
        #expect(blendWeight(position: 4, overlap: 4, isFirst: false) == 1.0)
    }

    @Test("extractLatentSubTensor extracts the exact requested latent region")
    func extractRegion() {
        // 1 channel, 1 frame, 4x4 spatial — latents = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]
        var latents = [Float](repeating: 0, count: 16)
        for i in 0 ..< 16 { latents[i] = Float(i) }

        let tile = extractLatentSubTensor(
            latents: latents,
            channels: 1, frames: 1,
            height: 4, width: 4,
            startT: 0, chunkT: 1,
            startH: 1, startW: 1,
            tileH: 2, tileW: 2
        )
        // Row-major: index(h,w) = h*4 + w;  requested (h in 1..2, w in 1..2) = {5,6,9,10}
        #expect(tile == [5, 6, 9, 10])
    }

    @Test("padLatentTile returns input unchanged when sizes match")
    func padNoop() {
        let tile: [Float] = [1, 2, 3, 4]
        let padded = padLatentTile(
            tile: tile, channels: 1,
            actualT: 1, actualH: 2, actualW: 2,
            targetT: 1, targetH: 2, targetW: 2
        )
        #expect(padded == tile)
    }

    @Test("padLatentTile zero-fills the extra boundary pixels")
    func padZeroFill() {
        let tile: [Float] = [1, 2, 3, 4]  // 1 channel, 1 frame, 2x2
        let padded = padLatentTile(
            tile: tile, channels: 1,
            actualT: 1, actualH: 2, actualW: 2,
            targetT: 1, targetH: 3, targetW: 3
        )
        #expect(padded.count == 9)
        #expect(padded[0] == 1)
        #expect(padded[1] == 2)
        #expect(padded[2] == 0)  // new column
        #expect(padded[3] == 3)
        #expect(padded[4] == 4)
        #expect(padded[5] == 0)  // new column
        #expect(padded[6] == 0)
        #expect(padded[7] == 0)
        #expect(padded[8] == 0)  // entire new row zero
    }

    @Test("blendTileIntoOutput: non-overlapping tiles produce clean copy")
    func blendNoOverlap() {
        // 1 channel, 1 frame, 4x4 output assembled from two 2x4 tiles (no overlap)
        var output = [Float](repeating: 0, count: 16)
        let tile1: [Float] = [1, 2, 3, 4, 5, 6, 7, 8]
        let tile2: [Float] = [9, 10, 11, 12, 13, 14, 15, 16]

        blendTileIntoOutput(
            output: &output, tilePixels: tile1,
            outputChannels: 1, outputFrames: 1, fullPixelH: 4, fullPixelW: 4,
            pixStartT: 0, pixStartH: 0, pixStartW: 0,
            pixTileT: 1, pixTileH: 2, pixTileW: 4,
            decodedStrideT: 1, decodedStrideH: 2, decodedStrideW: 4,
            pixelOverlapT: 0, pixelOverlapH: 0, pixelOverlapW: 0,
            isFirstTemporal: true, isFirstRow: true, isFirstCol: true
        )
        blendTileIntoOutput(
            output: &output, tilePixels: tile2,
            outputChannels: 1, outputFrames: 1, fullPixelH: 4, fullPixelW: 4,
            pixStartT: 0, pixStartH: 2, pixStartW: 0,
            pixTileT: 1, pixTileH: 2, pixTileW: 4,
            decodedStrideT: 1, decodedStrideH: 2, decodedStrideW: 4,
            pixelOverlapT: 0, pixelOverlapH: 0, pixelOverlapW: 0,
            isFirstTemporal: true, isFirstRow: true, isFirstCol: true
        )

        #expect(output == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
    }

    @Test("blendTileIntoOutput: overlapping tiles blend linearly at the shared boundary")
    func blendWithOverlap() {
        // 1 channel, 1 frame, 4x1 output from two 3x1 tiles with 2-pixel overlap
        var output = [Float](repeating: 0, count: 4)
        let tile1: [Float] = [10, 10, 10]
        let tile2: [Float] = [20, 20, 20]

        blendTileIntoOutput(
            output: &output, tilePixels: tile1,
            outputChannels: 1, outputFrames: 1, fullPixelH: 1, fullPixelW: 4,
            pixStartT: 0, pixStartH: 0, pixStartW: 0,
            pixTileT: 1, pixTileH: 1, pixTileW: 3,
            decodedStrideT: 1, decodedStrideH: 1, decodedStrideW: 3,
            pixelOverlapT: 0, pixelOverlapH: 0, pixelOverlapW: 0,
            isFirstTemporal: true, isFirstRow: true, isFirstCol: true
        )
        blendTileIntoOutput(
            output: &output, tilePixels: tile2,
            outputChannels: 1, outputFrames: 1, fullPixelH: 1, fullPixelW: 4,
            pixStartT: 0, pixStartH: 0, pixStartW: 1,
            pixTileT: 1, pixTileH: 1, pixTileW: 3,
            decodedStrideT: 1, decodedStrideH: 1, decodedStrideW: 3,
            pixelOverlapT: 0, pixelOverlapH: 0, pixelOverlapW: 2,
            isFirstTemporal: true, isFirstRow: true, isFirstCol: false
        )

        // pos 0: tile1 only = 10
        // pos 1: blend(tile1=10, tile2=20, weight = 0/2 = 0) -> 10
        // pos 2: blend(tile1=10, tile2=20, weight = 1/2 = 0.5) -> 15
        // pos 3: tile2 only (weight=1) = 20
        #expect(output[0] == 10.0)
        #expect(output[1] == 10.0)
        #expect(abs(output[2] - 15.0) < 1e-5)
        #expect(output[3] == 20.0)
    }
}
