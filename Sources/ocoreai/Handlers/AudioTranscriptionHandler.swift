// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AudioTranscriptionHandler.swift — `POST /v1/audio/transcriptions`, the wire surface for
/// 能听 (hearing): speech in, text out, on-device.
///
/// ### Why this endpoint exists
/// Until now the server could *record* a microphone sample (`POST /v1/multimodal/capture`)
/// and an agent could *transcribe* one through the `transcribe_audio` tool, but no HTTP
/// client could turn speech into text: `POST /v1/audio/transcriptions` answered 404
/// (measured 10-15, `scripts/probes/05-hearing.sh`). So the capability existed in the
/// process and was unreachable from the surface — the same shape as the other
/// accept-then-cannot-deliver defects this repo keeps fixing.
///
/// ### Why chat `audio_url` is not the same thing
/// Measured 10-15 on this host, posting a real 1.5 s utterance to `/v1/chat/completions` as
/// an `audio_url` part: `prompt_tokens` went **down** (705, vs 743 for the same prompt with
/// no audio), and the model answered *"Please provide the audio"* with HTTP 200. Zero audio
/// tokens reached the model. The cause is upstream and verified, not inferred:
/// `UserInput.audios` is plumbed through `Chat.Message`/`UserInput`, and `Gemma4.prepare`
/// consumes `LMInput.audio` (the checkpoint carries 754 `audio_tower.*` weights), but
/// **no `UserInputProcessor` in mlx-swift-lm reads `input.audios`** — `grep -c audios` in
/// `Gemma4.swift` is 0. Waveform therefore cannot reach the LLM at all today.
///
/// Consequence for this file: the honest route for speech is OS ASR → text, which is what
/// this endpoint does. It does not pretend to feed audio to the model, and it never returns
/// a transcript it did not measure (AGENTS.md invariant 2).
///
/// ### Shapes accepted (both, because clients differ)
/// * `multipart/form-data` — OpenAI's own shape: `file` (+ `model`, `language`,
///   `response_format`). A minimal strict parser lives in ``MultipartFormData``.
/// * `application/json` — `{"audio": "<data URL | base64>", "language": "…"}`, for clients
///   that cannot build multipart bodies. Extension, not spec; the endpoint note says so.
/// * `{"url": "file:///…"}` — local path only. `http(s)` is refused by name: fetching a
///   remote URL from a local-first server is an SSRF the product does not need.
///
/// `model` and `prompt` are accepted for client compatibility and **do not** change the
/// engine (the OS Speech analyzer is what runs); `response_format: "verbose_json"` and
/// `timestamp_granularities` are refused rather than quietly downgraded, because a response
/// that omits promised fields is exactly the over-claim this file exists to stop.
///
/// ### Refusals are typed and name the fix
/// `error_code` comes from ``TranscriptFailure`` (closed vocabulary), the message carries the
/// remedy (`System Settings ▸ Privacy & Security ▸ Speech Recognition`), and a measured
/// engine fault is a refusal — never an in-process call that could SIGTRAP the server
/// (`HearingReadiness` is the gate). An honest empty transcript (silence) stays 200 with
/// `speech_detected: false` and a `reason`, because "looked, found no speech" is a
/// measurement, not a failure.

import Foundation
import HTTPTypes
import Hummingbird
import Logging

#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - Request shape (JSON variant)

/// JSON body of `POST /v1/audio/transcriptions`.
///
/// Hand-decoded so every optional field is genuinely optional on the wire (AGENTS.md:
/// synthesized `Decodable` in this target requires every non-Optional key — the
/// `AnthropicMessageRequest.stream` 400 in the changelog is the same defect class).
struct TranscriptionJSONRequest: Decodable, Equatable, Sendable {
    /// Client-side model name. Accepted for compatibility; the engine is the OS analyzer.
    let model: String?
    /// BCP-47 language hint (`en`, `zh`, `en-US`, `zh-Hans-SG`).
    let language: String?
    /// Audio payload as a `data:` URL or a raw base64 string.
    let audio: String?
    /// Local `file://` path to an audio file. Remote URLs are refused.
    let url: String?
    /// OpenAI's optional initial-prompt bias — accepted, not applied.
    let prompt: String?
    /// `"json"` (default) | `"text"` | `"verbose_json"` (refused with a named reason).
    let responseFormat: String?
    /// Requested timestamp granularities — this engine provides none, so non-empty is refused.
    let timestampGranularities: [String]?

    enum CodingKeys: String, CodingKey {
        case model, language, audio, url, prompt
        case responseFormat = "response_format"
        case timestampGranularities = "timestamp_granularities"
    }
}

// MARK: - multipart/form-data

/// One field of a multipart body.
struct FormField: Equatable, Sendable {
    let name: String
    let filename: String?
    let contentType: String?
    let data: Data
}

/// Minimal strict `multipart/form-data` reader.
///
/// Kept here, small, and fully covered by `AudioTranscriptionTests` — the alternative
/// (claiming OpenAI multipart compatibility while only accepting JSON) would be a surface
/// promising what it does not do. Every failure mode returns an empty result or nil so the
/// handler can refuse with a reason; nothing here traps or guesses.
enum MultipartFormData {
    /// Pull the boundary out of a `Content-Type` header, honouring quotes and extra params.
    static func boundary(fromContentType header: String) -> String? {
        guard header.lowercased().contains("multipart/form-data") else { return nil }
        for rawParam in header.split(separator: ";") {
            let param = rawParam.trimmingCharacters(in: .whitespaces)
            guard param.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(param.dropFirst("boundary=".count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Split the body into fields. Malformed input yields `[]` (the caller refuses).
    static func parse(_ body: Data, boundary: String) -> [FormField] {
        guard !boundary.isEmpty, !body.isEmpty else { return [] }
        let delimiter = Data(("--" + boundary).utf8)
        var fields: [FormField] = []
        var segments: [Data] = []
        // Byte offsets, and `subdata(in:)` for every slice: `subdata` always hands back a
        // zero-based copy, so an index computed against `body` can never be reinterpreted
        // by a slice that kept its own offsets (the class of bug that makes a multipart
        // parser "work" on the fixture and corrupt real uploads).
        var searchStart = 0
        while searchStart < body.count,
            let range = body.range(of: delimiter, options: [], in: searchStart ..< body.count)
        {
            if range.lowerBound > searchStart {
                segments.append(body.subdata(in: searchStart ..< range.lowerBound))
            }
            searchStart = range.upperBound
        }
        if searchStart < body.count {
            segments.append(body.subdata(in: searchStart ..< body.count))
        }
        for segment in segments {
            guard let field = field(in: segment) else { continue }
            fields.append(field)
        }
        return fields
    }

    /// CRLF, the delimiter line terminator and the header/body separator.
    private static let crlf = Data([0x0d, 0x0a])
    private static let headerBlockEnd = Data([0x0d, 0x0a, 0x0d, 0x0a])
    private static let closeMarkers = Data("--".utf8)

    // `Data` has no `hasPrefix`/`hasSuffix` (measured: the build says "no such member"),
    // and a global extension to add them would be exactly the second abstraction this repo
    // tries not to grow — so the two comparisons a multipart parser actually needs live
    // here, on the byte lengths that make them total.
    private static func hasPrefix(_ data: Data, _ prefix: Data) -> Bool {
        guard data.count >= prefix.count else { return false }
        return data.subdata(in: 0 ..< prefix.count) == prefix
    }
    private static func hasSuffix(_ data: Data, _ suffix: Data) -> Bool {
        guard data.count >= suffix.count else { return false }
        return data.subdata(in: (data.count - suffix.count) ..< data.count) == suffix
    }

    /// Parse one segment (headers + CRLF + body) into a field.
    static func field(in segment: Data) -> FormField? {
        var payload = segment
        // Strip the CRLF that follows the delimiter line, and the trailing --/CRLF part.
        if hasPrefix(payload, crlf) {
            payload = payload.subdata(in: 2 ..< payload.count)
        }
        if hasPrefix(payload, closeMarkers) { return nil }  // closing delimiter
        if hasSuffix(payload, crlf) {
            payload = payload.subdata(in: 0 ..< (payload.count - 2))
        }
        guard payload.count >= 4 else { return nil }
        guard let headerEnd = payload.range(of: headerBlockEnd) else {
            return nil
        }
        let headerText =
            String(
                data: payload.subdata(in: 0 ..< headerEnd.lowerBound), encoding: .utf8) ?? ""
        let bodyData = payload.subdata(in: headerEnd.upperBound ..< payload.count)

        var name: String? = nil
        var filename: String? = nil
        var contentType: String? = nil
        for rawLine in headerText.split(separator: "\r\n") {
            let line = String(rawLine)
            let lower = line.lowercased()
            if lower.hasPrefix("content-disposition:") {
                let params = line.dropFirst("content-disposition:".count)
                let parameterText = String(params)
                // RFC 2045 allows a parameter value to be a token or a quoted-string, and real
                // clients emit both. Both keys resolve the same way: quoting is not a privilege,
                // and an asymmetric rule would drop the `name` of every unquoted part — which is
                // the part the whole body is keyed by.
                name =
                    quotedValue(in: parameterText, key: "name")
                    ?? bareValue(in: parameterText, key: "name")
                filename =
                    quotedValue(in: parameterText, key: "filename")
                    ?? bareValue(in: parameterText, key: "filename")
            } else if lower.hasPrefix("content-type:") {
                contentType = line.dropFirst("content-type:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        guard let resolvedName = name, !resolvedName.isEmpty else { return nil }
        return FormField(
            name: resolvedName, filename: filename, contentType: contentType, data: bodyData)
    }

    /// `key="value"` → value (with escaped quotes unescaped).
    static func quotedValue(in text: String, key: String) -> String? {
        let needle = key.lowercased() + "=\""
        guard let start = text.lowercased().range(of: needle) else { return nil }
        let after = text[start.upperBound...]
        var result = ""
        var index = after.startIndex
        while index < after.endIndex {
            let character = after[index]
            if character == "\\", after.index(after: index) < after.endIndex {
                result.append(after[after.index(after: index)])
                index = after.index(after: index)
                index = after.index(after: index)
                continue
            }
            if character == "\"" { return result }
            result.append(character)
            index = after.index(after: index)
        }
        return nil
    }

    /// `key=value` (unquoted, terminated by `;` or end) → value.
    static func bareValue(in text: String, key: String) -> String? {
        let needle = key.lowercased() + "="
        guard let start = text.lowercased().range(of: needle) else { return nil }
        let after = text[start.upperBound...]
        if after.first == "\"" { return nil }
        guard let end = after.firstIndex(of: ";") else {
            let value = after.trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        let value = after[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Where the audio came from

/// What the request actually delivered, after shape handling.
enum AudioInput: Equatable, Sendable {
    /// Bytes plus the MIME type the client claimed (nil when it did not claim one).
    case bytes(Data, mime: String?)
    /// A local file path (`file://` only).
    case localFile(URL)
    /// Nothing usable.
    case missing(TranscriptFailure)
}

// MARK: - Pure seams

/// Pure request/response decisions, so the wire contract is pinned by unit tests rather than
/// by a host that happens to have (or lack) a microphone.
enum AudioTranscription {
    /// Cap mirrors OpenAI's own limit for this endpoint (25 MB).
    static let maxBytes = 25 * 1024 * 1024

    /// Choose the audio source across the accepted shapes, in precedence order:
    /// multipart `file` → JSON `audio` → JSON `url`.
    static func resolveAudio(
        json: TranscriptionJSONRequest?,
        fields: [FormField],
        contentType: String?
    ) -> AudioInput {
        if let contentType, MultipartFormData.boundary(fromContentType: contentType) != nil {
            if let file = fields.first(where: { $0.name == "file" }) {
                if file.data.isEmpty { return .missing(.undecodableAudio) }
                if file.data.count > maxBytes { return .missing(.undecodableAudio) }
                return .bytes(file.data, mime: file.contentType)
            }
            // multipart body without a `file` part: the client sent the right envelope and
            // the wrong contents — say so, do not fall through to a guess.
            return .missing(.undecodableAudio)
        }
        if let audio = json?.audio, !audio.isEmpty {
            if audio.count > maxBytes * 2 { return .missing(.undecodableAudio) }
            guard let decoded = decodeBase64(audio) else { return .missing(.undecodableAudio) }
            if decoded.isEmpty { return .missing(.undecodableAudio) }
            return .bytes(decoded, mime: dataURLMimeType(audio))
        }
        if let raw = json?.url, !raw.isEmpty {
            return resolveURL(raw)
        }
        return .missing(.undecodableAudio)
    }

    /// `file://` only. `http(s)` is refused by name rather than fetched: a local-first
    /// server that fetches arbitrary URLs is an SSRF with no product need.
    static func resolveURL(_ raw: String) -> AudioInput {
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            return .missing(.undecodableAudio)
        }
        guard let url = URL(string: raw) else { return .missing(.undecodableAudio) }
        if url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
            return .localFile(url)
        }
        return .missing(.undecodableAudio)
    }

    /// Base64 body of a data URL (or a bare base64 string). Uses the LAST comma so a
    /// URL-encoded payload containing commas survives (same rule as `makeMLXAudio`).
    static func decodeBase64(_ raw: String) -> Data? {
        var payload = raw
        if payload.hasPrefix("data:") {
            guard let lastComma = payload.lastIndex(of: ",") else { return nil }
            payload = String(payload[payload.index(after: lastComma)...])
        }
        payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let strict = Data(base64Encoded: payload) { return strict }
        return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
    }

    /// MIME type declared by a data URL prefix, nil when it is a bare base64 string.
    static func dataURLMimeType(_ raw: String) -> String? {
        guard raw.hasPrefix("data:") else { return nil }
        guard let comma = raw.firstIndex(of: ",") else { return nil }
        // Drop the `data:` scheme by its own length. `index(after: startIndex)` skips one
        // character, not five, and measured "ata:audio/webm" — a mime that then picked the
        // staging container by coincidence ("…wav" still contains "wav") instead of by the
        // container the client claimed.
        let header = String(raw[raw.index(raw.startIndex, offsetBy: "data:".count) ..< comma])
        let head = header.split(separator: ";").first.map(String.init) ?? ""
        return head.isEmpty ? nil : head
    }

    /// Extension to write the decoded bytes under, from the claimed MIME type.
    ///
    /// Matters: `makeMLXAudio` names every temp file `.caf` regardless of payload, and
    /// AVFoundation's sniffing is not a contract. Writing the container the client
    /// actually sent keeps the decoder honest.
    static func fileExtension(forMime mime: String?, fallback: String = "wav") -> String {
        guard let mime else { return fallback }
        let lower = mime.lowercased()
        // Container fidelity, in container-before-codec order: `audio/ogg; codecs=opus` is an
        // Ogg container, so "ogg" is checked before "opus". ADTS AAC gets `.aac` rather than
        // being folded into the ISO-BMFF container it is not.
        if lower.contains("wave") || lower.contains("/wav") { return "wav" }
        if lower.contains("mpeg") || lower.contains("mp3") { return "mp3" }
        if lower.contains("ogg") { return "ogg" }
        if lower.contains("mp4") || lower.contains("m4a") { return "m4a" }
        if lower.contains("aac") { return "aac" }
        if lower.contains("flac") { return "flac" }
        if lower.contains("opus") { return "opus" }
        if lower.contains("aiff") || lower.contains("aif") { return "aiff" }
        if lower.contains("caf") { return "caf" }
        if lower.contains("webm") { return "webm" }
        if lower.contains("amr") { return "amr" }
        return fallback
    }

    /// Language hint → locale. OpenAI sends ISO-639-1 (`en`); browsers send BCP-47
    /// (`en-US`). Unknown/absent falls back to the user's current locale, which is what the
    /// OS resolves against anyway.
    static func locale(from language: String?) -> Locale {
        guard let language else { return .current }
        let trimmed = language.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .current }
        return Locale(identifier: trimmed)
    }

    /// Validate `response_format` / `timestamp_granularities` before doing any work, so a
    /// client asking for fields this engine cannot produce gets a named refusal.
    static func unsupportedField(json: TranscriptionJSONRequest?, fields: [FormField]) -> String? {
        let format =
            json?.responseFormat
            ?? fields.first(where: { $0.name == "response_format" })?.utf8Value
        if let format, format == "verbose_json" {
            return "response_format=verbose_json is not provided by this engine — "
                + "supported: json (default), text"
        }
        if let json, !(json.timestampGranularities ?? []).isEmpty {
            return "timestamp_granularities is not provided by this engine — "
                + "the OS analyzer reports no word/segment timestamps"
        }
        return nil
    }

    /// Build the HTTP body for a measured transcript. Pure.
    static func successBody(
        transcript: HearingTranscript,
        requestedLanguage: String?,
        reason: TranscriptFailure? = nil
    ) -> TranscriptionResponse {
        TranscriptionResponse(
            text: transcript.text,
            language: transcript.locale,
            requestedLanguage: requestedLanguage,
            duration: transcript.durationSeconds,
            speechDetected: transcript.detected,
            engine: transcript.engine,
            reason: reason?.rawValue
        )
    }

    /// Build the HTTP body for an honest failure. Pure.
    static func failureBody(_ failure: TranscriptFailure) -> TranscriptionResponse {
        TranscriptionResponse(
            text: "",
            language: nil,
            requestedLanguage: nil,
            duration: nil,
            // The two measured-emptiness outcomes carry the detector's answer, because the
            // header of this file promises `speech_detected: false` for silence — and a 200
            // that stays silent about whether anything was listened to is the over-claim this
            // file exists to stop. Refusals keep the field absent: no listening, no field.
            speechDetected: failure.detectedSpeech,
            engine: HearingReadiness.engineName,
            reason: failure.rawValue
        )
    }

    /// Status for a failure: payload problems are the client's (400); permission, locale and
    /// engine state are service state the user must fix (503). "Looked, found no speech" is
    /// never an error — see the file header.
    static func status(for failure: TranscriptFailure) -> HTTPResponse.Status {
        switch failure {
        case .undecodableAudio:
            return .badRequest
        case .osUnsupported, .speechNotDetermined, .speechDenied, .speechRestricted,
            .localeUnsupported, .engineFault, .engineRefused, .engineTimeout:
            return .serviceUnavailable
        case .noSpeechDetected, .emptyTranscript:
            return .ok
        }
    }

    /// The `AppError` for a failure, at the status this table assigns it.
    ///
    /// One factory, so every route that hears audio answers one failure with one status.
    /// Before it existed the throw site had only `.transcriptionUnavailable` (503) available,
    /// so `.undecodableAudio` — which this very function classifies as the client's 400 —
    /// left the process as 503 "service unavailable, retry", advice that is wrong for bytes
    /// that will never decode. The chat route (`ChatAudioIngestion`) throws through here for
    /// the same reason.
    static func appError(for failure: TranscriptFailure) -> AppError {
        if status(for: failure) == .badRequest {
            return .transcriptionRejected(
                errorCode: failure.errorCode, reason: failure.remediation)
        }
        return .transcriptionUnavailable(
            errorCode: failure.errorCode, reason: failure.remediation)
    }

    /// Silence for the `text` response format: the transcript itself, UTF-8.
    static func plainText(_ text: String) -> Data { Data(text.utf8) }
}

extension FormField {
    /// Field value as UTF-8 text (for the non-file fields of a multipart body).
    var utf8Value: String? {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Response shape

/// Body of `POST /v1/audio/transcriptions`.
///
/// `text`/`language`/`duration` match OpenAI so standard clients keep working; the rest is
/// ocoreai-specific and carries what the engine actually did (`engine`, `speech_detected`,
/// `reason`) so a 200 never has to be trusted on faith.
struct TranscriptionResponse: Encodable, Equatable, Sendable {
    let text: String
    let language: String?
    let requestedLanguage: String?
    let duration: Double?
    let speechDetected: Bool?
    let engine: String
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case text, language, engine, reason
        case requestedLanguage = "requested_language"
        case duration
        case speechDetected = "speech_detected"
    }
}

// MARK: - Handler

/// `POST /v1/audio/transcriptions` — body already collected by the router.
///
/// The router hands over raw bytes because the accepted shapes differ by `Content-Type`, and
/// `request.decode(as:)` would reject a legal multipart body before this function could read
/// it (the `AnthropicMessageRequest.stream` lesson, applied one level up).
func audioTranscriptionsHandler(
    contentType: String?,
    body: Data,
    localeHint: String?,
    logger: Logger
) async throws -> Response {
    var json: TranscriptionJSONRequest? = nil
    var fields: [FormField] = []

    if let contentType, let boundary = MultipartFormData.boundary(fromContentType: contentType) {
        fields = MultipartFormData.parse(body, boundary: boundary)
    } else {
        json = try? JSONDecoder().decode(TranscriptionJSONRequest.self, from: body)
    }

    let requestedLanguage =
        json?.language ?? fields.first(where: { $0.name == "language" })?
        .utf8Value ?? localeHint

    if let why = AudioTranscription.unsupportedField(json: json, fields: fields) {
        throw AppError.invalidAudio(reason: why)
    }

    let source = AudioTranscription.resolveAudio(
        json: json, fields: fields, contentType: contentType)

    let audioURL: URL
    var tempFile: URL? = nil
    switch source {
    case .missing(let failure):
        throw AppError.invalidAudio(
            reason: "\(failure.remediation) (reason=\(failure.rawValue))")
    case .localFile(let url):
        audioURL = url
    case .bytes(let data, let mime):
        if data.count > AudioTranscription.maxBytes {
            throw AppError.invalidAudio(
                reason: "Audio exceeds the \(AudioTranscription.maxBytes / (1024 * 1024)) MB cap"
            )
        }
        let written = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ocoreai-asr-\(UUID().uuidString.prefix(8))."
                    + AudioTranscription.fileExtension(forMime: mime))
        do {
            try data.write(to: written)
            tempFile = written
            audioURL = written
        } catch {
            throw AppError.invalidAudio(reason: "Could not stage the audio payload for decoding")
        }
    }
    defer {
        if let tempFile { try? FileManager.default.removeItem(at: tempFile) }
    }

    let locale = AudioTranscription.locale(from: requestedLanguage)
    let outcome = await Hearing.transcribe(file: audioURL, locale: locale)

    switch outcome {
    case .success(let transcript):
        // The message stays one interpolated literal (`Logger.Message` is
        // ExpressibleByStringInterpolation, and `"a" + "b"` is a plain String, which does not
        // convert); the detail goes where logs are queryable — metadata.
        logger.info(
            "Transcribed \(transcript.text.count) chars via \(transcript.engine)",
            metadata: [
                "engine": .string(transcript.engine),
                "locale": .string(transcript.locale),
                "detected": .string(String(transcript.detected)),
            ])
        let wantsPlainText =
            (json?.responseFormat
                ?? fields.first(where: { $0.name == "response_format" })?
                .utf8Value) == "text"
        if wantsPlainText {
            var headers: HTTPFields = [:]
            headers[.contentType] = "text/plain; charset=utf-8"
            return Response(
                status: .ok, headers: headers,
                body: .init(
                    byteBuffer: ByteBuffer(
                        data: AudioTranscription.plainText(
                            transcript.text))))
        }
        return try transcriptionJSON(
            AudioTranscription.successBody(
                transcript: transcript, requestedLanguage: requestedLanguage),
            status: .ok)
    case .failure(let failure):
        let status = AudioTranscription.status(for: failure)
        logger.warning(
            "Transcription refused: \(failure.rawValue) — \(failure.remediation)",
            metadata: [
                "error_code": .string(failure.errorCode), "locale": .string(locale.identifier),
            ])
        if status == .ok {
            // Measured emptiness, not a failure: silence is a result. Report it truthfully
            // instead of either inventing words or returning an error the client must parse.
            return try transcriptionJSON(
                AudioTranscription.failureBody(failure), status: .ok)
        }
        throw AudioTranscription.appError(for: failure)
    }
}

/// Encode a body with an explicit status. Local because both neighbouring `json` helpers in
/// this target are `fileprivate` and hardcode `.ok`.
private func transcriptionJSON(
    _ value: some Encodable, status: HTTPResponse.Status
) throws -> Response {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Encode before the body closure: Hummingbird's writer closure is `@Sendable` and
    // `some Encodable` is not, while `Data` is — the same shape `json(...)` in
    // `MultimodalHandler.swift` uses, so this target has one way to answer with JSON.
    let data = try encoder.encode(value)
    var headers: HTTPFields = [:]
    headers[.contentType] = "application/json"
    return Response(
        status: status,
        headers: headers,
        body: .init { writer in
            try await writer.write(ByteBuffer(data: data))
            try await writer.finish(nil)
        }
    )
}
