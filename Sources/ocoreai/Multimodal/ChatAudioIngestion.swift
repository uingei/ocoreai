// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatAudioIngestion.swift — what `/v1/chat/completions` does with audio it cannot deliver.
///
/// ### The measurement this rests on
/// At the pinned mlx-swift-lm revision (`4cc550451`, what `.build-clt` resolves), `audios`
/// appears in exactly three files under `Libraries/` — `Chat.swift`, `UserInput.swift`,
/// `ChatSession.swift` — all of it plumbing that carries the array, and `audio` appears
/// **zero** times under `Libraries/MLXVLMCommon`: no model `UserInputProcessor` consumes
/// it. Waveform therefore cannot reach any model through the engine today. Live consequence
/// (measured 10-15, `scripts/probes/06-chat-audio.sh`): a 1.5 s utterance posted as an
/// `audio_url` part returned HTTP 200 while `prompt_tokens` went *down* (705 vs 743 for
/// the same prompt with no audio), and the model answered "Please provide the audio".
///
/// That is AGENTS.md invariant 2 wearing a speaker: the surface accepted the request,
/// answered 200, and dropped the only payload the client cared about. At that moment three
/// routes are open — deliver the speech, refuse it, or say nothing — and the third is the
/// bug. This file makes the third unreachable:
///
///   * every `audio_url` part is transcribed through the OS seam (`Hearing`, the same gate
///     `/v1/audio/transcriptions` uses — silently, never prompting, never running a pass
///     that could SIGTRAP the server), and what it heard replaces the part in the turn that
///     spoke it, tagged with the locale that resolved;
///   * if nothing can hear it, the request is refused with a typed `error_code` naming the
///     fix, before the scheduler or an engine handle is touched;
///   * measured silence stays a result rather than an error: the turn carries
///     `[heard … no speech detected]` and the request continues, because "listened, found
///     no speech" is a measurement, not a failure.
///
/// ### Why the answer is disclosed
/// "The model answered what you said" and "the model answered what OS ASR heard" are two
/// different claims. ``ChatCompletion.audioInput`` says which one happened, in the response
/// body, whenever the request carried audio. Streaming cannot carry it without inventing an
/// SSE field clients do not expect, so the streamed route logs the same fact instead — and
/// the refusal, which is the part that protects a client from a blind answer, behaves
/// identically in both modes because it happens before any token is produced.
///
/// ### Reuses rather than re-authors
/// Decoding, container sniffing, size caps and the failure→status mapping come from
/// ``AudioTranscription`` (`Handlers/AudioTranscriptionHandler.swift`); the ASR pass and
/// its permission/locale/probe gate come from ``Hearing``. One vocabulary per axis, so the
/// dedicated endpoint and the chat route cannot publish two meanings of `speech_denied`.

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// One heard audio part, after the OS analyzer has had its turn.
struct HeardAudio: Equatable, Sendable {
    /// What was heard. `nil` when nothing was heard (see `silent`).
    let text: String?
    /// The locale the analyzer resolved, when it got far enough to resolve one.
    let locale: String?
    /// The pass ran and found no speech — a measurement, not a refusal.
    let silent: Bool
    /// Engine that produced the text (``HearingReadiness/engineName`` today).
    let engine: String

    static func heard(_ text: String, locale: String, engine: String) -> HeardAudio {
        HeardAudio(text: text, locale: locale, silent: false, engine: engine)
    }

    static let silentNoSpeech = HeardAudio(text: nil, locale: nil, silent: true, engine: "none")
}

/// What `/v1/chat/completions` did with the audio a client attached. Encoded as
/// `audio_input`; absent when the request carried no audio (absence = "no audio here",
/// which is a different claim from "audio delivered").
struct ChatAudioInput: Codable, Equatable, Sendable {
    /// Audio parts the client attached and this server listened to.
    let parts: Int
    /// How many of them produced words.
    let transcribed: Int
    /// Always the OS analyzer: the model received text, never waveform.
    let engine: String
    /// Locales that actually resolved, per heard part (deduplicated, in order).
    let locales: [String]
    /// Characters of speech added to the prompt as text.
    let characters: Int

    enum CodingKeys: String, CodingKey {
        case parts, transcribed, engine, locales, characters
    }
}

/// The rewritten request plus its disclosure.
struct ChatAudioIngested: Sendable {
    var messages: [Message]
    var audioInput: ChatAudioInput?
}

enum ChatAudio {
    /// Can the engine carry waveform bytes into a model?
    ///
    /// Measured NO at the pinned revision — see the file header for the two greps and the
    /// live 200-with-no-audio run. `ChatAudioIngestionTests` pins this to `false` so that
    /// the day upstream grows an audio `UserInputProcessor`, flipping it is a deliberate,
    /// tested act rather than a silent change of behaviour.
    static var modelConsumesAudio: Bool { false }

    /// Cap on audio parts heard per request. Not a spec limit — a bound on how much wall
    /// time one chat turn can spend in ASR; past it the request is refused loudly rather
    /// than quietly listening to some parts and dropping the rest.
    static let maxPartsPerRequest = 8

    /// Every `audio_url` in the conversation, in wire order, with the message it belongs to.
    /// Pure — the extraction the splice and the refusal both key off.
    static func audioParts(in messages: [Message]) -> [(messageIndex: Int, url: String)] {
        var found: [(messageIndex: Int, url: String)] = []
        for (index, message) in messages.enumerated() {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                if let audio = part.audioURL, !audio.url.isEmpty {
                    found.append((index, audio.url))
                }
            }
        }
        return found
    }

    /// Replace each audio part with the text it said, keeping every other part untouched.
    ///
    /// The audio part is *removed*, not left alongside its transcript: leaving it in the
    /// turn would keep handing the engine a payload it cannot deliver, which is the defect
    /// this file exists to close. A message whose only part was audio becomes a plain text
    /// turn, and therefore stops being routed as a media request it cannot satisfy.
    ///
    /// Each transcript takes the slot the audio occupied, so a turn that interleaved
    /// "translate this:" / ⟨audio⟩ / "into French" keeps that order — the client wrote the
    /// instruction around the payload, and the payload's words belong in the same place.
    static func spliced(
        _ messages: [Message], heard: [(messageIndex: Int, audio: HeardAudio)]
    ) -> [Message] {
        guard !heard.isEmpty else { return messages }
        // Group by message; `ingest` appends in wire order, so each queue is in the order
        // the audio parts appeared inside that message.
        var byMessage: [Int: [HeardAudio]] = [:]
        for entry in heard {
            byMessage[entry.messageIndex, default: []].append(entry.audio)
        }
        var out = messages
        for index in byMessage.keys {
            guard index < out.count, case .parts(let parts) = out[index].content else { continue }
            var pending = byMessage[index] ?? []
            var rebuilt: [ContentPart] = []
            rebuilt.reserveCapacity(parts.count)
            for part in parts {
                if part.audioURL == nil {
                    rebuilt.append(part)
                } else if !pending.isEmpty {
                    rebuilt.append(
                        ContentPart(
                            type: "text", text: heardMarker(pending.removeFirst()), imageUrl: nil))
                }
                // An audio part nothing was heard from, with nothing left in the queue, is
                // dropped: `audio_input` already says how many parts arrived and how many
                // produced words, so the count is disclosed rather than implied by silence.
            }
            out[index].content = .parts(rebuilt)
        }
        return out
    }

    /// The text that stands in for one heard part: tagged with the locale that resolved, and
    /// explicit when the pass ran and found nothing — the marker is what lets a reader of the
    /// transcript tell "the machine heard these words" from "the machine heard nothing".
    private static func heardMarker(_ audio: HeardAudio) -> String {
        let locale = audio.locale.map { " · \($0)" } ?? ""
        if !audio.silent, let text = audio.text, !text.isEmpty {
            return "[heard\(locale)] \(text)"
        }
        return "[heard\(locale) no speech detected]"
    }

    /// Disclose the hearing that happened, or `nil` when there was nothing to hear.
    static func report(
        parts: Int, heard: [HeardAudio], engine: String
    ) -> ChatAudioInput? {
        guard parts > 0 else { return nil }
        var locales: [String] = []
        var characters = 0
        var transcribed = 0
        for audio in heard {
            if let locale = audio.locale, !locales.contains(locale) { locales.append(locale) }
            if let text = audio.text, !text.isEmpty {
                transcribed += 1
                characters += text.count
            }
        }
        return ChatAudioInput(
            parts: parts, transcribed: transcribed, engine: engine, locales: locales,
            characters: characters)
    }

    /// Listen to everything the conversation carries and rewrite it as text, or say why
    /// that was impossible. Refusals are fatal to the request (never a blind 200);
    /// measured silence is not.
    static func ingest(
        in messages: [Message], localeHint: String? = nil
    ) async -> Result<ChatAudioIngested, TranscriptFailure> {
        let found = audioParts(in: messages)
        guard !found.isEmpty else {
            return .success(ChatAudioIngested(messages: messages, audioInput: nil))
        }
        guard !modelConsumesAudio else {
            // Upstream can take waveform: nothing to substitute, nothing to disclose.
            return .success(ChatAudioIngested(messages: messages, audioInput: nil))
        }
        guard found.count <= maxPartsPerRequest else {
            return .failure(.undecodableAudio)
        }

        let locale = AudioTranscription.locale(from: localeHint)
        var heard: [(messageIndex: Int, audio: HeardAudio)] = []
        var staged: [URL] = []
        defer { for url in staged { try? FileManager.default.removeItem(at: url) } }

        for entry in found {
            switch await hear(url: entry.url, locale: locale, staged: &staged) {
            case .success(let audio):
                heard.append((entry.messageIndex, audio))
            case .failure(let failure):
                // "Looked, found no speech" is a result: disclose it and carry on. Anything
                // else means the words never arrived, and answering anyway would be the
                // confident-wrong-answer this file names in its header.
                if AudioTranscription.status(for: failure) == .ok {
                    heard.append((entry.messageIndex, .silentNoSpeech))
                } else {
                    return .failure(failure)
                }
            }
        }
        return .success(
            ChatAudioIngested(
                messages: spliced(messages, heard: heard),
                audioInput: report(
                    parts: found.count, heard: heard.map(\.audio),
                    engine: HearingReadiness.engineName)))
    }

    /// Materialise one `audio_url` (data URL / bare base64 / `file://`) and run it through
    /// the OS seam. Remote URLs are refused by name, same rule as the transcription
    /// endpoint: a local-first server that fetches arbitrary URLs is an SSRF with no
    /// product need.
    private static func hear(
        url: String, locale: Locale, staged: inout [URL]
    ) async -> Result<HeardAudio, TranscriptFailure> {
        let stagedURL: URL? = {
            // Inline first: a chat part is normally a data URL (or bare base64), and
            // `resolveURL` does not decode either — it only accepts `file://`.
            if url.hasPrefix("data:") || !url.contains("://") {
                guard let decoded = AudioTranscription.decodeBase64(url), !decoded.isEmpty else {
                    return nil
                }
                let written = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "ocoreai-chat-asr-\(UUID().uuidString.prefix(8))."
                            + AudioTranscription.fileExtension(
                                forMime: AudioTranscription.dataURLMimeType(url)))
                do {
                    try decoded.write(to: written)
                    staged.append(written)
                    return written
                } catch {
                    return nil
                }
            }
            switch AudioTranscription.resolveURL(url) {
            case .localFile(let existing): return existing
            case .bytes, .missing: return nil
            }
        }()
        guard let fileURL = stagedURL else { return .failure(.undecodableAudio) }

        switch await Hearing.transcribe(file: fileURL, locale: locale) {
        case .success(let transcript):
            return .success(
                .heard(transcript.text, locale: transcript.locale, engine: transcript.engine))
        case .failure(let failure):
            return .failure(failure)
        }
    }
}
