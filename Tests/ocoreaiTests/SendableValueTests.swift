// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SendableValueTests.swift — SQLite 值包装器单元测试
///
/// Covers: init(rawValue:) dispatch, casting methods (asInt64/asDouble/
/// asString/asData), null handling, and cross-actor Sendable safety.

#if canImport(Testing)
import Testing
import Foundation
@testable import ocoreai

// MARK: - Case construction

@Suite("SendableValue 构造")
struct SendableValueConstructionTests {
    @Test("直接 case 构造保留精确值")
    func directConstruction() {
        let intVal = SendableValue.integer(Int64(42))
        let floatVal = SendableValue.float(3.14159)
        let textVal = SendableValue.text("hello")
        let blobVal = SendableValue.blob(Data([0x48, 0x65, 0x6c, 0x6c, 0x6f]))
        let nullVal = SendableValue.null

        #expect(intVal.asInt64 == 42)
        #expect(floatVal.asDouble == 3.14159)
        #expect(textVal.asString == "hello")
        #expect(blobVal.asData == Data([0x48, 0x65, 0x6c, 0x6c, 0x6f]))
        #expect(nullVal.asInt64 == nil)
        #expect(nullVal.asDouble == nil)
        #expect(nullVal.asString == nil)
        #expect(nullVal.asData == nil)
    }

    @Test("integer case 的 asInt64 返回正确值")
    func integerExtraction() {
        let val = SendableValue.integer(Int64.max)
        #expect(val.asInt64 == Int64.max)
        #expect(val.asDouble == nil)
        #expect(val.asString == nil)
        #expect(val.asData == nil)
    }

    @Test("float case 的 asDouble 返回正确值")
    func floatExtraction() {
        let val = SendableValue.float(Double.pi)
        #expect(val.asDouble == Double.pi)
        #expect(val.asInt64 == nil)
        #expect(val.asString == nil)
        #expect(val.asData == nil)
    }

    @Test("text case 的 asString 返回正确值")
    func textExtraction() {
        let val = SendableValue.text("测试文字")
        #expect(val.asString == "测试文字")
        #expect(val.asInt64 == nil)
        #expect(val.asDouble == nil)
        #expect(val.asData == nil)
    }

    @Test("blob case 的 asData 返回正确值")
    func blobExtraction() {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let val = SendableValue.blob(Data(bytes))
        #expect(val.asData == Data(bytes))
        #expect(val.asInt64 == nil)
        #expect(val.asDouble == nil)
        #expect(val.asString == nil)
    }
}

// MARK: - init(rawValue:) dispatch

@Suite("SendableValue.init(rawValue:) 分派")
struct SendableValueRawValueDispatchTests {
    @Test("Int64 值分发到 .integer")
    func dispatchInt64() {
        let val = SendableValue(rawValue: Int64(12345))
        #expect(val.asInt64 == 12345)
    }

    @Test("Int 值分发到 .integer")
    func dispatchInt() {
        let val = SendableValue(rawValue: Int(99))
        #expect(val.asInt64 == 99)
    }

    @Test("UInt64 值分发到 .integer")
    func dispatchUInt64() {
        let val = SendableValue(rawValue: UInt64(777))
        #expect(val.asInt64 == 777)
    }

    @Test("Double 值分发到 .float")
    func dispatchDouble() {
        let val = SendableValue(rawValue: Double(2.718))
        #expect(val.asDouble == 2.718)
    }

    @Test("Float 值分发到 .float")
    func dispatchFloat() {
        let val = SendableValue(rawValue: Float(1.414))
        #expect(val.asDouble == Double(1.414))
    }

    @Test("String 值分发到 .text")
    func dispatchString() {
        let val = SendableValue(rawValue: "raw-value-test")
        #expect(val.asString == "raw-value-test")
    }

    @Test("Data 值分发到 .blob")
    func dispatchData() {
        let data = Data([1, 2, 3, 4])
        let val = SendableValue(rawValue: data)
        #expect(val.asData == data)
    }

    @Test("NSNull 分发到 .null")
    func dispatchNSNull() {
        let val = SendableValue(rawValue: NSNull())
        switch val {
        case .null: break
        default:
            Issue.record("NSNull 应分发到 .null")
        }
    }

    @Test("nil (Optional) 分发到 .null")
    func dispatchNil() {
        let optional: String? = nil
        let val = SendableValue(rawValue: optional as Any)
        switch val {
        case .null: break
        default:
            Issue.record("nil 应分发到 .null")
        }
    }
}

// MARK: - rawValue accessor

@Suite("SendableValue.rawValue 访问器")
struct SendableValueRawValueAccessorTests {
    @Test("rawValue 返回正确的底层类型")
    func rawValueReturnsCorrectType() {
        let intVal = SendableValue.integer(Int64(100))
        #expect(intVal.rawValue as? Int64 == 100)

        let floatVal = SendableValue.float(42.0)
        #expect(floatVal.rawValue as? Double == 42.0)

        let textVal = SendableValue.text("raw")
        #expect(textVal.rawValue as? String == "raw")

        let blobVal = SendableValue.blob(Data([42]))
        #expect(blobVal.rawValue as? Data == Data([42]))

        let nullVal = SendableValue.null
        #expect(nullVal.rawValue is NSNull)
    }
}

// MARK: - Cross-actor Sendable safety

actor SendableValueActor {
    private var stored: SendableValue = .null

    func store(_ value: SendableValue) {
        self.stored = value
    }

    func fetchInt64() -> Int64? {
        return self.stored.asInt64
    }

    func fetchDouble() -> Double? {
        return self.stored.asDouble
    }

    func fetchString() -> String? {
        return self.stored.asString
    }

    func fetchData() -> Data? {
        return self.stored.asData
    }
}

@Suite("SendableValue 跨 actor 安全传递")
struct SendableValueSendableTests {
    @Test("SendableValue 可安全传入 actor 并读取")
    func crossActorInt64() async {
        let actor = SendableValueActor()
        await actor.store(.integer(Int64(42)))
        let result = await actor.fetchInt64()
        #expect(result == 42)
    }

    @Test("SendableValue.float 可跨 actor 传递")
    func crossActorFloat() async {
        let actor = SendableValueActor()
        await actor.store(.float(3.14))
        let result = await actor.fetchDouble()
        #expect(result == 3.14)
    }

    @Test("SendableValue.text 可跨 actor 传递")
    func crossActorText() async {
        let actor = SendableValueActor()
        await actor.store(.text("跨 actor 测试"))
        let result = await actor.fetchString()
        #expect(result == "跨 actor 测试")
    }

    @Test("SendableValue.blob 可跨 actor 传递")
    func crossActorBlob() async {
        let actor = SendableValueActor()
        let data = Data([0xAA, 0xBB, 0xCC])
        await actor.store(.blob(data))
        let result = await actor.fetchData()
        #expect(result == data)
    }

    @Test("SendableValue.null 可跨 actor 传递")
    func crossActorNull() async {
        let actor = SendableValueActor()
        await actor.store(.null)
        #expect(await actor.fetchInt64() == nil)
        #expect(await actor.fetchDouble() == nil)
        #expect(await actor.fetchString() == nil)
        #expect(await actor.fetchData() == nil)
    }

    @Test("多次读写保持值一致性")
    func crossActorConsistency() async {
        let actor = SendableValueActor()
        let values: [SendableValue] = [
            .integer(Int64(1)),
            .float(2.5),
            .text("three"),
            .blob(Data([3])),
            .null,
        ]
        for v in values {
            await actor.store(v)
            let i = await actor.fetchInt64()
            let d = await actor.fetchDouble()
            let s = await actor.fetchString()
            let b = await actor.fetchData()
            switch v {
            case .integer(let iv):
                #expect(i == iv)
                #expect(d == nil && s == nil && b == nil)
            case .float(let fv):
                #expect(d == fv)
                #expect(i == nil && s == nil && b == nil)
            case .text(let tv):
                #expect(s == tv)
                #expect(i == nil && d == nil && b == nil)
            case .blob(let bv):
                #expect(b == bv)
                #expect(i == nil && d == nil && s == nil)
            case .null:
                #expect(i == nil && d == nil && s == nil && b == nil)
            }
        }
    }
}

#endif
