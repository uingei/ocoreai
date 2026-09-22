// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `/v1/models` wire 形状回归 — 纯 Codable,不依赖 MLX/EnginePool,任何环境可跑。
///
/// 锚定:
///   - `object == "list"` / `"model"`(OpenAI 客户端靠它识别模型列表)
///   - ocreai 扩展字段 `state`/`vlm`/`weightsDir` — nil 时**不出现**
///     (encodeIfPresent),非 nil 时必须出现且值正确

import Foundation
import Testing

@testable import ocoreai

@Suite("Models endpoint — wire shape (pure Codable)")
struct ModelsWireShapeTests {

    @Test("ModelListResponse 含 object=list + data 数组")
    func listShape() throws {
        let objects = [
            ModelObject(
                id: "mlx-community/Qwen3.5-4B-MLX-4bit",
                state: "ready", vlm: true, weightsDir: "/x"),
            ModelObject(id: "Qwen2.5-1.5B-CoreAI/q", state: "loading"),
            ModelObject(id: "local/abs", state: "ready", vlm: false),
        ]
        let body = String(
            decoding: try JSONEncoder().encode(ModelListResponse(data: objects)),
            as: UTF8.self)
        #expect(body.contains(#""object":"list""#))
        #expect(body.contains(#""object":"model""#))
        #expect(body.contains(#""data":["#))
    }

    @Test("可选字段 nil → 不序列化")
    func optionalOmission() throws {
        let m = ModelObject(id: "only-id", state: nil, vlm: nil, weightsDir: nil)
        let body = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        #expect(!body.contains(#""state""#))
        #expect(!body.contains(#""vlm""#))
        #expect(!body.contains(#""weightsDir""#))
        #expect(body.contains(#""id":"only-id""#))
        #expect(body.contains(#""ownedBy":"ocoreai""#))
    }

    @Test("vlm=true/false 都正确落 wire — 客户端据此区分 VLM")
    func vlmBothValues() throws {
        let t = String(
            decoding: try JSONEncoder().encode(
                ModelObject(id: "a", state: "ready", vlm: true)), as: UTF8.self)
        let f = String(
            decoding: try JSONEncoder().encode(
                ModelObject(id: "b", state: "ready", vlm: false)), as: UTF8.self)
        #expect(t.contains(#""vlm":true"#))
        #expect(f.contains(#""vlm":false"#))
    }
}
