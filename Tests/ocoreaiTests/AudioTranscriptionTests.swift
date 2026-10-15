// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AudioTranscriptionTests.swift — pin the wire contract of `POST /v1/audio/transcriptions`.
///
/// Why these are here (AGENTS.md invariant 1: a claim is worth exactly the gate that goes red
/// when it breaks): the endpoint's header promises four things a client acts on — that it
/// accepts OpenAI's multipart shape *and* a JSON extension, that every optional field is
/// optional on the wire, that remote `url` is refused rather than fetched, and that a refusal
/// names the axis (permission / locale / engine) instead of being a bare 500. None of that was
/// asserted anywhere: the file that makes the promises did not even compile when this suite
/// was written (`Data` has no `hasPrefix`/`hasSuffix`, and `MultipartFormData.boundary` was
/// called unqualified from a neighbouring type), which is what a gate is for.
///
/// Everything here is offline and hardware-free: no Speech framework call, no microphone, no
/// model. The measured-availability half lives in `HearingHonestyTests`; the live end-to-end
/// half is `scripts/probes/05-hearing.sh`.

import Foundation
import Hummingbird
import Testing

@testable import ocoreai

// MARK: - fixtures

/// Decode a JSON body into the request DTO, or nil (the tests assert the nil cases).
private func request(_ body: String) -> TranscriptionJSONRequest? {
    try? JSONDecoder().decode(TranscriptionJSONRequest.self, from: Data(body.utf8))
}

private func encoded(_ value: some Encodable & Sendable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

/// An RFC-correct `multipart/form-data` body, built byte by byte so the parser is tested
/// against what clients actually send rather than against a shorthand of our own invention.
private func multipart(
    boundary: String = "ocoreai-test-boundary-9f3",
    parts: [(disposition: String, contentType: String?, body: Data)]
) -> Data {
    var out = Data()
    for part in parts {
        out.append(Data("--\(boundary)\r\n".utf8))
        out.append(Data(part.disposition.utf8))
        if let contentType = part.contentType {
            out.append(Data("\r\nContent-Type: \(contentType)".utf8))
        }
        // Exactly one blank line between headers and body: a second CRLF makes the fixture
        // non-conformant, and a parser honouring RFC 2046 would (correctly) hand the extra
        // CRLF back as the first two bytes of the payload. Measured, on this fixture.
        out.append(Data("\r\n\r\n".utf8))
        out.append(part.body)
        out.append(Data("\r\n".utf8))
    }
    out.append(Data("--\(boundary)--\r\n".utf8))
    return out
}

private let wavType = "multipart/form-data; boundary=ocoreai-test-boundary-9f3"

/// Bytes that would break any parser tempted to treat a part body as text: a NUL, a lone CR,
/// a byte >0x7F, and a substring that looks like a delimiter prefix without being one.
private let awkwardAudioBytes = Data([0x00, 0x0d, 0xff, 0x52, 0x49, 0x46, 0x46])

// MARK: - Content-Type / boundary

@Test(
    "the boundary survives every legal Content-Type spelling",
    arguments: [
        ("multipart/form-data; boundary=ABC", "ABC"),
        ("multipart/form-data; boundary=\"ABC\"", "ABC"),
        ("Multipart/Form-Data; charset=utf-8; boundary=xy9", "xy9"),
        ("multipart/form-data;boundary=no-space", "no-space"),
        ("application/json", nil),
        ("multipart/form-data", nil),
        ("multipart/form-data; boundary=", nil),
    ] as [(header: String, want: String?)])
func boundaryExtraction(header: String, want: String?) {
    #expect(MultipartFormData.boundary(fromContentType: header) == want)
}

@Test("a body is only treated as multipart when its own Content-Type says so")
func multipartRequiresItsContentType() {
    // A JSON body must never be scanned as multipart: the field extractor would find nothing
    // and the client would get "no audio" instead of a parse of what it sent.
    let body = Data(#"{"audio":"aGVsbG8="}"#.utf8)
    #expect(MultipartFormData.boundary(fromContentType: "application/json") == nil)
    #expect(MultipartFormData.parse(body, boundary: "ocoreai-test-boundary-9f3").isEmpty)
}

// MARK: - multipart parsing

@Test("a real multipart body parses into its fields, byte-exact")
func multipartParsesFieldsExactly() throws {
    let body = multipart(
        parts: [
            (
                disposition: #"Content-Disposition: form-data; name="file"; filename="say hi.wav""#,
                contentType: "audio/wav", body: awkwardAudioBytes
            ),
            (
                disposition: #"Content-Disposition: form-data; name="language""#, contentType: nil,
                body: Data("zh".utf8)
            ),
            (
                disposition: #"Content-Disposition: form-data; name="response_format""#,
                contentType: nil, body: Data("json".utf8)
            ),
        ])

    let fields = MultipartFormData.parse(body, boundary: "ocoreai-test-boundary-9f3")
    #expect(fields.count == 3)

    let file = fields[0]
    #expect(file.name == "file")
    #expect(file.filename == "say hi.wav")
    #expect(file.contentType == "audio/wav")
    // Byte-for-byte: a NUL and a high byte survive the round trip, so nothing decoded the
    // payload as UTF-8 text on the way through.
    #expect(file.data == awkwardAudioBytes)
    #expect(fields[1].name == "language")
    #expect(fields[1].utf8Value == "zh")
    #expect(fields[2].utf8Value == "json")
    // The closing delimiter is not a fourth field, and no field is named after punctuation.
    #expect(!fields.contains { $0.name.hasPrefix("--") })
}

@Test(
    "malformed bodies yield no fields rather than a guess",
    arguments: [
        ("empty body", Data([0x0d, 0x0a]), "bnd"),
        (
            "wrong boundary",
            Data(
                "--other\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\nx\r\n--other--\r\n"
                    .utf8), "bnd"
        ),
        ("delimiter with no header block", Data("--bnd\r\nnonsense\r\n--bnd--\r\n".utf8), "bnd"),
        ("no delimiter at all", Data("just some bytes".utf8), "bnd"),
        (
            "header block never terminated",
            Data("--bnd\r\nContent-Disposition: form-data; name=\"file\"\r\n".utf8), "bnd"
        ),
        ("empty boundary", Data("--bnd\r\nname=file\r\n\r\nx\r\n".utf8), ""),
    ] as [(name: String, body: Data, boundary: String)])
func malformedMultipart(name: String, body: Data, boundary: String) {
    #expect(MultipartFormData.parse(body, boundary: boundary).isEmpty, "\(name) produced fields")
}

@Test("an unterminated quoted value is refused, never guessed at")
func unterminatedQuoteRefuses() {
    // `filename="a.wav` with no closing quote is not a value to invent one for, and `name=`
    // is a suffix of `filename=`, so a key match must not land mid-word — otherwise a part
    // carrying only a filename masquerades as `name="a.wav"`.
    let unterminated = MultipartFormData.field(
        in: Data("Content-Disposition: form-data; name=\"file\"; filename=\"a.wav\r\n\r\nx".utf8))
    #expect(unterminated?.name == "file")
    #expect(unterminated?.filename == nil)

    let onlyFilename = MultipartFormData.field(
        in: Data(#"Content-Disposition: form-data; filename="a.wav""#.utf8))
    #expect(onlyFilename == nil, "filename= matched the name= key")
}

@Test("a part without a name is dropped; a name without quotes still resolves")
func fieldNameResolution() {
    let anonymous = MultipartFormData.field(
        in: Data("Content-Type: audio/wav\r\n\r\nbytes".utf8))
    #expect(anonymous == nil)

    let bare = MultipartFormData.field(
        in: Data("Content-Disposition: form-data; name=language\r\n\r\nen".utf8))
    #expect(bare?.name == "language")
    #expect(bare?.filename == nil)
    #expect(bare?.data == Data("en".utf8))
}

@Test(
    "quoted values unescape, bare values stop at the next parameter",
    arguments: [
        (#"form-data; name="file""#, "name", "file"),
        (#"form-data; filename="say \"hi\".wav""#, "filename", "say \"hi\".wav"),
        (#"form-data; name="file"; filename="a.wav""#, "filename", "a.wav"),
        (#"form-data; name="file""#, "filename", nil),
    ] as [(params: String, key: String, want: String?)])
func quotedValues(params: String, key: String, want: String?) {
    #expect(MultipartFormData.quotedValue(in: params, key: key) == want)
}

@Test(
    "bare parameter values",
    arguments: [
        ("form-data; name=file", "name", "file"),
        ("form-data; name=file; filename=x", "name", "file"),
        ("form-data; name=  spaced  ", "name", "spaced"),
        ("form-data; name=\"quoted\"", "name", nil),
        ("form-data; other=x", "name", nil),
    ] as [(params: String, key: String, want: String?)])
func bareValues(params: String, key: String, want: String?) {
    #expect(MultipartFormData.bareValue(in: params, key: key) == want)
}

// MARK: - JSON DTO: optionality is the contract

@Test("every optional field is genuinely optional on the wire")
func emptyJSONObjectDecodes() throws {
    // The synthesized Decodable in this target requires every non-Optional key; the
    // `AnthropicMessageRequest.stream` 400 is the same defect class, so the empty body —
    // which a client may legitimately send to learn what is missing — must decode.
    let minimal = try JSONDecoder().decode(TranscriptionJSONRequest.self, from: Data("{}".utf8))
    #expect(minimal.model == nil)
    #expect(minimal.language == nil)
    #expect(minimal.audio == nil)
    #expect(minimal.url == nil)
    #expect(minimal.prompt == nil)
    #expect(minimal.responseFormat == nil)
    #expect(minimal.timestampGranularities == nil)
}

@Test("snake_case fields and unknown extras decode without disturbing the contract")
func fullJSONBody() throws {
    let full = try #require(
        request(
            """
            {"model":"gemma-4","language":"en","audio":"aGVsbG8=","prompt":"hello",
             "response_format":"verbose_json","timestamp_granularities":["word"],
             "task":"transcribe","temperature":0}
            """))
    #expect(full.model == "gemma-4")
    #expect(full.language == "en")
    #expect(full.audio == "aGVsbG8=")
    #expect(full.prompt == "hello")
    #expect(full.responseFormat == "verbose_json")
    #expect(full.timestampGranularities == ["word"])
}

// MARK: - where the audio came from

@Test("multipart with a file part delivers those bytes")
func multipartFilePartIsTheAudio() throws {
    let body = multipart(
        parts: [
            (
                disposition: #"Content-Disposition: form-data; name="file"; filename="a.wav""#,
                contentType: "audio/wav", body: awkwardAudioBytes
            )
        ])
    let fields = MultipartFormData.parse(body, boundary: "ocoreai-test-boundary-9f3")
    #expect(
        AudioTranscription.resolveAudio(json: nil, fields: fields, contentType: wavType)
            == .bytes(awkwardAudioBytes, mime: "audio/wav"))
}

@Test("a multipart envelope with no file part refuses instead of falling through")
func multipartWithoutFileRefuses() {
    let fields = [
        FormField(name: "language", filename: nil, contentType: nil, data: Data("en".utf8))
    ]
    // The right envelope with the wrong contents is a named client error; silently ignoring
    // the multipart body to go look at JSON would answer a different question than asked.
    #expect(
        AudioTranscription.resolveAudio(
            json: request(#"{"audio":"aGVsbG8="}"#), fields: fields, contentType: wavType)
            == .missing(.undecodableAudio))
    #expect(
        AudioTranscription.resolveAudio(json: nil, fields: [], contentType: wavType)
            == .missing(.undecodableAudio))
}

@Test("an empty file part is undecodable audio, not silence")
func emptyFilePartIsNotSilence() {
    let fields = [
        FormField(
            name: "file", filename: "empty.wav", contentType: "audio/wav",
            data: Data())
    ]
    #expect(
        AudioTranscription.resolveAudio(json: nil, fields: fields, contentType: wavType)
            == .missing(.undecodableAudio))
}

@Test("json audio arrives as bytes, with the mime the data URL declared")
func jsonAudioShape() {
    let hello = Data("hello".utf8)
    #expect(
        AudioTranscription.resolveAudio(
            json: request(#"{"audio":"data:audio/mpeg;base64,aGVsbG8=","language":"en"}"#),
            fields: [], contentType: nil) == .bytes(hello, mime: "audio/mpeg"))
    // A bare base64 string (no data URL) is legal too, and declares no mime.
    #expect(
        AudioTranscription.resolveAudio(
            json: request(#"{"audio":"aGVsbG8="}"#), fields: [], contentType: nil)
            == .bytes(hello, mime: nil))
}

@Test(
    "nothing usable is refused by name, never answered as silence",
    arguments: [
        ("empty body", "{}"),
        ("empty audio", #"{"audio":""}"#),
        ("not base64", #"{"audio":"not*base64!"}"#),
        ("remote http", #"{"url":"http://example.com/a.wav"}"#),
        ("remote https", #"{"url":"https://example.com/a.wav"}"#),
        ("no audio field at all", #"{"language":"en","model":"gemma-4"}"#),
        (
            "local file that is not there",
            #"{"url":"file:///tmp/ocoreai-absent-\#(UUID().uuidString).wav"}"#
        ),
    ] as [(name: String, body: String)])
func unusableInputRefuses(name: String, body: String) throws {
    let json = try #require(request(body))
    let input = AudioTranscription.resolveAudio(json: json, fields: [], contentType: nil)
    switch input {
    case .missing(.undecodableAudio):
        break  // the one right answer for every row
    default:
        Issue.record("\(name): expected undecodableAudio, got \(input)")
    }
}

@Test("a remote url is refused by name, not fetched")
func remoteUrlIsNotFetched() {
    // A local-first server that fetches arbitrary URLs is an SSRF with no product need, so
    // the refusal happens in a pure seam that a test can prove never touches the network.
    #expect(
        AudioTranscription.resolveURL("https://example.com/a.wav") == .missing(.undecodableAudio))
    #expect(
        AudioTranscription.resolveURL("HTTP://example.com/a.wav") == .missing(.undecodableAudio))
    #expect(AudioTranscription.resolveURL("") == .missing(.undecodableAudio))
}

// MARK: - base64 / containers / locale

@Test("data URL payloads decode, keeping the last comma as the separator")
func dataUrlDecoding() {
    let hello = Data("hello".utf8)
    #expect(AudioTranscription.decodeBase64("data:audio/wav;base64,aGVsbG8=") == hello)
    #expect(AudioTranscription.decodeBase64("aGVsbG8=") == hello)
    // Whitespace-wrapped payloads are what real clients send.
    #expect(AudioTranscription.decodeBase64("\n aGVsbG8= \n") == hello)
    // A data URL whose payload contains a comma must split at the LAST comma, or a
    // URL-encoded payload is truncated mid-stream.
    #expect(
        AudioTranscription.decodeBase64("data:application/octet-stream,AAAA") == Data([0, 0, 0]))
    #expect(AudioTranscription.decodeBase64("data:audio/wav") == nil)
    #expect(AudioTranscription.decodeBase64("not*base64!") == nil)
    #expect(AudioTranscription.dataURLMimeType("data:audio/webm;codecs=opus,AAAA") == "audio/webm")
    #expect(AudioTranscription.dataURLMimeType("aGVsbG8=") == nil)
}

@Test(
    "the container the client claimed is the container we stage it under",
    arguments: [
        ("audio/wav", "wav"),
        ("audio/x-wav", "wav"),
        ("audio/mpeg", "mp3"),
        ("audio/mp3", "mp3"),
        ("audio/mp4", "m4a"),
        ("audio/aac", "aac"),
        ("audio/flac", "flac"),
        ("audio/ogg", "ogg"),
        ("audio/opus", "opus"),
        ("audio/aiff", "aiff"),
        ("audio/caf", "caf"),
        ("audio/webm", "webm"),
        ("audio/amr", "amr"),
        ("audio/wave", "wav"),
        // Container beats codec: this one says Ogg and carries an Opus payload.
        ("audio/ogg; codecs=opus", "ogg"),
        ("application/octet-stream", "wav"),
        (nil, "wav"),
    ] as [(mime: String?, want: String)])
func containerFromMime(mime: String?, want: String) {
    #expect(AudioTranscription.fileExtension(forMime: mime) == want)
}

@Test("a language hint names a locale; no hint falls back to this box, never a guess")
func languageToLocale() {
    #expect(AudioTranscription.locale(from: nil) == .current)
    #expect(AudioTranscription.locale(from: "") == .current)
    #expect(AudioTranscription.locale(from: "   ") == .current)
    #expect(AudioTranscription.locale(from: "zh").identifier == "zh")
    #expect(AudioTranscription.locale(from: " en-US ").identifier == "en-US")
}

// MARK: - refused fields

@Test("a field this engine cannot honour is refused by name, before any work")
func unsupportedFields() throws {
    let verbose = try #require(request(#"{"audio":"aGVsbG8=","response_format":"verbose_json"}"#))
    let why = AudioTranscription.unsupportedField(json: verbose, fields: [])
    #expect(why?.contains("verbose_json") == true)
    // The refusal names what IS available, so the client can fix it without reading source.
    #expect(why?.contains("json") == true)

    let stamps = try #require(
        request(#"{"audio":"aGVsbG8=","timestamp_granularities":["word"]}"#))
    #expect(
        AudioTranscription.unsupportedField(json: stamps, fields: [])?.contains(
            "timestamp_granularities") == true)

    // multipart carries the same field, and must be refused the same way.
    let formFields = [
        FormField(
            name: "response_format", filename: nil, contentType: nil,
            data: Data("verbose_json".utf8))
    ]
    #expect(
        AudioTranscription.unsupportedField(json: nil, fields: formFields)?.contains("verbose_json")
            == true)
}

@Test("the formats this engine does provide are not refused")
func supportedFormatsPass() throws {
    for format in ["json", "text"] {
        let body = try #require(request(#"{"audio":"aGVsbG8=","response_format":"\#(format)"}"#))
        #expect(
            AudioTranscription.unsupportedField(json: body, fields: []) == nil, "\(format) refused")
    }
    #expect(AudioTranscription.unsupportedField(json: request("{}"), fields: []) == nil)
    // An empty granularities array asks for nothing, so it is not a refusal.
    let emptyStamps = try #require(request(#"{"audio":"aGVsbG8=","timestamp_granularities":[]}"#))
    #expect(AudioTranscription.unsupportedField(json: emptyStamps, fields: []) == nil)
}

// MARK: - status codes: who has to act

@Test(
    "every failure is routed to whoever can fix it",
    arguments: [
        (TranscriptFailure.undecodableAudio, 400),
        (TranscriptFailure.osUnsupported, 503),
        (TranscriptFailure.speechNotDetermined, 503),
        (TranscriptFailure.speechDenied, 503),
        (TranscriptFailure.speechRestricted, 503),
        (TranscriptFailure.localeUnsupported, 503),
        (TranscriptFailure.engineFault, 503),
        (TranscriptFailure.engineRefused, 503),
        (TranscriptFailure.engineTimeout, 503),
        // "Looked, found no speech" is a measurement, not an error: it must not cost a
        // retry, and must not look like the service is down.
        (TranscriptFailure.noSpeechDetected, 200),
        (TranscriptFailure.emptyTranscript, 200),
    ] as [(failure: TranscriptFailure, code: Int)])
func failureStatus(failure: TranscriptFailure, code: Int) {
    #expect(AudioTranscription.status(for: failure).code == code)
}

@Test("the status table covers the whole vocabulary, so a new case forces a decision")
func failureStatusCoversVocabulary() {
    // Floor the scan itself: if the vocabulary silently grew or the table stopped matching,
    // the per-case test above would pass on fewer rows and nobody would notice.
    #expect(TranscriptFailure.allCases.count == 11)
    let codes = Dictionary(grouping: TranscriptFailure.allCases) {
        AudioTranscription.status(for: $0).code
    }
    #expect(codes[400]?.count == 1)
    #expect(codes[503]?.count == 8)
    #expect(codes[200]?.count == 2)
}

// MARK: - response bodies

@Test("a success body carries what the engine measured, not what was configured")
func successBodyShape() throws {
    let transcript = HearingTranscript(
        text: " 你好 ", engine: "apple-speech-analyzer", detected: true,
        locale: "zh-CN", durationSeconds: 1.5)
    let body = AudioTranscription.successBody(transcript: transcript, requestedLanguage: "zh")
    #expect(body.text == " 你好 ")
    let json = try encoded(body)
    #expect(json["text"] as? String == " 你好 ")
    #expect(json["language"] as? String == "zh-CN")
    #expect(json["requested_language"] as? String == "zh")
    #expect(json["duration"] as? Double == 1.5)
    #expect(json["speech_detected"] as? Bool == true)
    #expect(json["engine"] as? String == "apple-speech-analyzer")
    // Nothing measured → nothing published: a successful response has no reason.
    #expect(json["reason"] == nil)
}

@Test("silence reports that it listened; a refusal reports that it did not")
func failureBodiesReportTheDetectorHonestly() throws {
    // The endpoint header promises `speech_detected: false` for silence. That is only true
    // if the body actually says so — a 200 that omits the field leaves the client to guess
    // whether anyone listened.
    let silence = try encoded(AudioTranscription.failureBody(.noSpeechDetected))
    #expect(silence["speech_detected"] as? Bool == false)
    #expect(silence["reason"] as? String == "noSpeechDetected")
    #expect(silence["text"] as? String == "")

    let empty = try encoded(AudioTranscription.failureBody(.emptyTranscript))
    #expect(empty["speech_detected"] as? Bool == true)

    // Refused before listening: the field is absent, which is a different claim from false.
    let refused = try encoded(AudioTranscription.failureBody(.speechDenied))
    #expect(refused["speech_detected"] == nil)
    #expect(refused["reason"] as? String == "speechDenied")
    #expect(refused["duration"] == nil)
    #expect(refused["language"] == nil)
}

@Test("`response_format: text` returns the transcript itself, UTF-8")
func plainTextFormat() {
    #expect(AudioTranscription.plainText("你好 world") == Data("你好 world".utf8))
    #expect(AudioTranscription.plainText("") == Data())
}

@Test("the machine code and the closed vocabulary cannot drift apart")
func errorCodeDerivation() {
    #expect(TranscriptFailure.engineFault.errorCode == "engine_fault")
    #expect(TranscriptFailure.speechNotDetermined.errorCode == "speech_not_determined")
    #expect(TranscriptFailure.osUnsupported.errorCode == "os_unsupported")
    // Every code is snake_case and unique — the property clients branch on.
    let codes = TranscriptFailure.allCases.map(\.errorCode)
    #expect(Set(codes).count == TranscriptFailure.allCases.count)
    for code in codes {
        #expect(
            code.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil,
            "\(code) is not snake_case")
    }
}

@Test("every refusal states a fix a human can carry out")
func remediationIsActionable() {
    for failure in TranscriptFailure.allCases {
        #expect(!failure.remediation.isEmpty, "\(failure.rawValue) has no remediation")
    }
    // The three permission outcomes all point at the same pane, named.
    for failure in [
        TranscriptFailure.speechNotDetermined, .speechDenied, .speechRestricted,
    ] {
        #expect(
            failure.remediation.contains("Speech Recognition"),
            "\(failure.rawValue) does not name the settings pane")
    }
}
