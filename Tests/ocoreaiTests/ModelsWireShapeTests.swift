// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `/v1/models` wire 形状回归 — 纯 Codable,不依赖 MLX/EnginePool,任何环境可跑。
///
/// 锚定:
///   - `object == "list"` / `"model"`(OpenAI 客户端靠它识别模型列表)
///   - 规范两键 `owned_by` / `created` — vllm 与 sglang 都发(sglang
///     `srt/entrypoints/openai/protocol.py:87-95`、vllm
///     `entrypoints/serve/engine/protocol.py:105-114`),`openai-python` 的 `Model` 读这两个名。
///     本行 11-02 之前发的是 `ownedBy` 且**没有** `created`,而下面这条测试当年把 `ownedBy`
///     钉成了断言——钉住偏离的门比没有门更糟(同一族见 CHANGELOG 11-01 Anthropic delta 判别符),
///     所以现在钉的是规范名,并加了一条「struct 有字段却上不了线」的自检。
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
        // The spec's spelling, not this object's camelCase: `openai-python`'s `Model` reads
        // `owned_by`, and the deviation this line used to pin is why that client saw no owner.
        #expect(body.contains(#""owned_by":"ocoreai""#), "wire keys: \(body)")
        #expect(!body.contains(#""ownedBy""#), "the camelCase rename came back: \(body)")
        #expect(
            body.contains("\"created\":"),
            "`created` left the row — openai-python's Model requires it: \(body)")
    }

    /// One row with every stored property populated. A field added to `ModelObject` without a
    /// `CodingKeys` case encodes as nothing at all — the row silently loses a promise, and no
    /// per-field assertion notices unless someone thinks to write one. This reflects the struct,
    /// so forgetting is caught by the same test that reads the wire.
    private static func fullRow() -> ModelObject {
        var row = ModelObject(
            id: "m", object: "model", created: 1_700_000_000, ownedBy: "ocoreai",
            state: "ready", vlm: true, weightsDir: "/x", capabilities: ["embed"],
            defaultModel: true, videoInput: "delivered",
            videoEvidence: "1 turn", toolCallDelivery: "parsed", toolCallEvidence: "1 call",
            reasoningEffort: "honored",
            loadProgress: ModelLoadProgress(
                elapsedSeconds: 1, downloading: false, bytesDownload: nil, bytesTotal: nil,
                bytesPerSecond: nil, secondsRemainingEstimate: nil)
        )
        // Through the setter, because that is the only place the two spellings are ever written.
        row.setContextCeiling(4096)
        return row
    }

    @Test(
        "every stored property of the row reaches the wire — a CodingKeys row cannot be forgotten")
    func modelRowCarriesEveryStoredProperty() throws {
        let full = Self.fullRow()
        let reflected = Mirror(reflecting: full).children.compactMap(\.label)
        // Floor on the fixture's own premise: a new field nobody populated here must be named,
        // not silently dropped from the comparison below.
        #expect(reflected.count == 17, "the fixture does not populate every field: \(reflected)")
        // The two keys whose spelling is not this object's camelCase. A third rename without a row
        // here reds below (the struct's name would appear on neither side of the diff), which is
        // the point: the mapping cannot silently lag the DTO.
        let renamed = ["ownedBy": "owned_by", "maxModelLen": "max_model_len"]
        let expected = Set(reflected.map { renamed[$0] ?? $0 })
        let data = try JSONEncoder().encode(full)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "the row did not encode to an object")
        let onWire = Set(json.keys)
        #expect(onWire == expected, "on the wire \(onWire) vs struct \(expected)")
        #expect(onWire.contains("owned_by") && onWire.contains("created"))
    }

    @Test("the ceiling is published under the references' name, alias carrying the same number")
    func ceilingPublishedUnderBothNames() throws {
        // `max_model_len` is what both stacks call it (`vllm .../engine/protocol.py:112`,
        // `sglang .../openai/protocol.py:94`); `contextLength` is the older spelling kept one
        // release. One value written by one setter — so the assertion is that the two AGREE, not
        // that each is populated, which is what would drift.
        var row = ModelObject(id: "m", state: "ready")
        row.setContextCeiling(8192)
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        #expect(json["max_model_len"] as? Int == 8192, "the references' key is missing: \(json)")
        #expect(json["contextLength"] as? Int == 8192, "the alias disagrees with the key: \(json)")

        // A row whose ceiling is unknown omits both — never 0, which a client sizes a prompt with.
        let unknown = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(ModelObject(id: "m")))
                as? [String: Any])
        #expect(
            unknown["max_model_len"] == nil && unknown["contextLength"] == nil,
            "an unknown ceiling published as a number: \(unknown)")
    }

    @Test("`created` is measured, and the same row reads the same on the next poll")
    func createdIsMeasuredNotListTime() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mws_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stamped = ModelRowClock.created(weightsDir: dir)
        let birth = try #require(
            (try FileManager.default.attributesOfItem(atPath: dir.path)[.creationDate]) as? Date,
            "the test filesystem stores no creation date — the fallback is what is being measured")
        #expect(stamped == Int(birth.timeIntervalSince1970), "not the directory's own date")
        #expect(ModelRowClock.created(weightsDir: dir) == stamped, "created moved between polls")
        // A row with no directory names the instant this server came to know it — never 0, which
        // a client reads as 1970.
        #expect(ModelRowClock.created(weightsDir: nil) == ModelRowClock.firstRowEpochSeconds)
        #expect(ModelRowClock.firstRowEpochSeconds > 1_000_000_000)
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
