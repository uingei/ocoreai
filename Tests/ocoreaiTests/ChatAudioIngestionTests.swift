// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatAudioIngestionTests.swift — audio on `/v1/chat/completions` gets heard, or refused,
/// or the request never reaches a 200. The route that used to happen — 200 OK with the
/// audio silently gone — is pinned out of existence here.
///
/// Why the stakes (AGENTS.md invariant 2, measured 10-15): at the pinned mlx-swift-lm
/// revision nothing under `Libraries/MLXVLMCommon` mentions `audio` at all, so a posted
/// `audio_url` cannot reach a model; the request still answered 200, `prompt_tokens` went
/// down, and the model said "Please provide the audio". A client cannot distinguish that
/// from success, and a user gets a confident answer to a question that was never heard.
///
/// No hardware, no microphone, no Speech permission required: extraction, splice, disclosure
/// and the refusal paths are all decided before the OS is touched, which is exactly why
/// they can be gated here rather than noted as unmeasurable.

import Foundation
import Hummingbird
import Testing

@testable import ocoreai

private func textPart(_ s: String) -> ContentPart {
    ContentPart(type: "text", text: s, imageUrl: nil)
}

private func audioPart(_ url: String) -> ContentPart {
    var part = ContentPart(type: "audio_url", text: nil, imageUrl: nil)
    part.audioURL = ContentPart.AudioURL(url: url)
    return part
}

private func partsMessage(_ parts: [ContentPart], role: String = "user") -> Message {
    Message(role: role, content: .parts(parts))
}

/// Byte-identical wire equality.
///
/// `Message` deliberately has no `Equatable` conformance (it is a wire DTO; adding it would
/// ripple through `ContentPart`/`ContentPolymorphic`/`ToolCall` just to satisfy an
/// assertion). What these tests claim is that the *request a client sent* came out
/// unchanged, which is precisely what the encoded bytes say — so compare those, with
/// `.sortedKeys`.
///
/// Why the formatter is not optional (measured 10-16, `make test-clt`): Foundation's JSON
/// writer does not guarantee key order across `JSONEncoder` instances, so encoding the same
/// value twice answered
///   `{"content":[…],"role":"user"}` vs `{"role":"user","content":[…]}`
/// and
///   `{"type":"audio_url","audio_url":{…}}` vs `{"audio_url":{…},"type":"audio_url"}`.
/// A byte comparison without sorted keys therefore asserts a property the encoder never
/// promised: "splicing nothing leaves the conversation byte-identical" failed while the two
/// documents were structurally identical. Same lesson as AGENTS.md invariant 1 — a check
/// that infers its premises from its environment rots; here the premise was key ordering.
private func sameWire(_ lhs: [Message], _ rhs: [Message]) throws -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(lhs) == encoder.encode(rhs)
}

@Suite("Chat audio — two honest routes, and the silent 200 is not one of them")
struct ChatAudioIngestionTests {

    @Test("the engine cannot take waveform today, and that stays a decision not an accident")
    func modelConsumesAudioIsPinnedFalse() {
        // Flip this only with upstream evidence that a UserInputProcessor consumes
        // `input.audios`; `ChatAudioIngestion`'s header names the two greps.
        #expect(ChatAudio.modelConsumesAudio == false)
    }

    @Test("audio parts are found in wire order, with the turn they belong to")
    func extraction() {
        let conversation: [Message] = [
            Message(role: "system", content: "be terse"),
            partsMessage([textPart("what did I say?"), audioPart("file:///tmp/a.caf")]),
            Message(role: "assistant", content: "you said nothing"),
            partsMessage([audioPart("data:audio/wav;base64,AAAA"), textPart("and now?")]),
        ]
        let found = ChatAudio.audioParts(in: conversation)
        #expect(found.count == 2)
        #expect(found[0].messageIndex == 1)
        #expect(found[0].url == "file:///tmp/a.caf")
        #expect(found[1].messageIndex == 3)
        #expect(found[1].url == "data:audio/wav;base64,AAAA")

        // Text-only conversations are untouched by this whole path.
        #expect(
            ChatAudio.audioParts(in: [Message(role: "user", content: "hello")]).isEmpty)
    }

    @Test("the transcript takes the audio's slot, in order, and the payload stays out")
    func spliceReplacesInPlaceRatherThanAppending() {
        let messages = [
            partsMessage([
                textPart("repeat this"), audioPart("data:audio/wav;base64,AAAA"),
                textPart("thanks"),
            ])
        ]
        let out = ChatAudio.spliced(
            messages,
            heard: [(0, HeardAudio.heard("你好", locale: "zh_CN", engine: "apple-speech"))])

        guard case .parts(let parts) = out[0].content else {
            Issue.record("content should stay multi-part")
            return
        }
        // The client wrote its instruction around the payload, so the payload's words belong
        // in the slot the payload occupied — not parked at the end of the turn.
        #expect(parts.count == 3)
        #expect(parts[0].text == "repeat this")
        #expect(parts[1].text == "[heard · zh_CN] 你好")
        #expect(parts[2].text == "thanks")
        // The undeliverable payload is gone, not parked next to its own transcript.
        #expect(parts.allSatisfy { $0.audioURL == nil })
        #expect(out[0].hasMediaPart == false)
    }

    @Test("two audio parts keep their own slots and their own transcripts")
    func spliceKeepsOrderAcrossMultipleParts() {
        let out = ChatAudio.spliced(
            [
                partsMessage([
                    textPart("first:"), audioPart("data:audio/wav;base64,AAAA"),
                    textPart("then:"), audioPart("data:audio/wav;base64,BBBB"),
                    textPart("end"),
                ])
            ],
            heard: [
                (0, HeardAudio.heard("one", locale: "en_US", engine: "apple-speech")),
                (0, HeardAudio.silentNoSpeech),
            ])
        guard case .parts(let parts) = out[0].content else {
            Issue.record("expected parts")
            return
        }
        #expect(
            parts.compactMap { $0.text }
                == ["first:", "[heard · en_US] one", "then:", "[heard no speech detected]", "end"])
    }

    @Test("an audio-only turn becomes a plain text turn")
    func audioOnlyTurn() {
        let out = ChatAudio.spliced(
            [partsMessage([audioPart("data:audio/wav;base64,AAAA")])],
            heard: [(0, HeardAudio.heard("hello there", locale: "en_US", engine: "apple-speech"))])
        guard case .parts(let parts) = out[0].content else {
            Issue.record("expected parts")
            return
        }
        #expect(parts.count == 1)
        #expect(parts[0].type == "text")
        #expect(parts[0].text == "[heard · en_US] hello there")
        #expect(out[0].hasMediaPart == false)
    }

    @Test("measured silence is disclosed, never invented into words")
    func silenceIsDisclosed() {
        let out = ChatAudio.spliced(
            [partsMessage([audioPart("data:audio/wav;base64,AAAA")])],
            heard: [(0, HeardAudio.silentNoSpeech)])
        guard case .parts(let parts) = out[0].content else {
            Issue.record("expected parts")
            return
        }
        #expect(parts.count == 1)
        #expect(parts[0].text == "[heard no speech detected]")
    }

    @Test("splicing nothing leaves the conversation byte-identical")
    func spliceIsIdentityWhenNothingWasHeard() throws {
        let messages = [partsMessage([textPart("hi"), audioPart("file:///tmp/a.caf")])]
        #expect(try sameWire(ChatAudio.spliced(messages, heard: []), messages))
    }

    @Test("the disclosure counts parts, words, and locales separately")
    func report() {
        #expect(ChatAudio.report(parts: 0, heard: [], engine: "x") == nil)
        let mixed = ChatAudio.report(
            parts: 3,
            heard: [
                HeardAudio.heard("你好", locale: "zh_CN", engine: "apple-speech"),
                HeardAudio.silentNoSpeech,
                HeardAudio.heard("ok", locale: "zh_CN", engine: "apple-speech"),
            ],
            engine: "apple-speech-analyzer")
        #expect(
            mixed
                == ChatAudioInput(
                    parts: 3, transcribed: 2, engine: "apple-speech-analyzer",
                    locales: ["zh_CN"], characters: 4))
    }

    @Test("a remote audio URL is refused before anything is fetched or answered")
    func remoteURLIsRefusedNotDropped() async {
        let result = await ChatAudio.ingest(
            in: [partsMessage([textPart("listen"), audioPart("https://example.com/a.wav")])])
        switch result {
        case .success:
            Issue.record("a remote audio part must not sail through to a 200")
        case .failure(let failure):
            #expect(failure == .undecodableAudio)
            #expect(failure.errorCode == "undecodable_audio")
            // 400: the payload is the client's to fix, not the service's.
            #expect(AudioTranscription.status(for: failure).code == 400)
        }
    }

    @Test("undecodable inline audio is a typed refusal, not an empty turn")
    func badBase64IsRefused() async {
        let result = await ChatAudio.ingest(
            in: [partsMessage([audioPart("data:audio/wav;base64,!!!not-base64!!!")])])
        switch result {
        case .success:
            Issue.record("garbage bytes must not become a successful turn")
        case .failure(let failure):
            #expect(failure == .undecodableAudio)
        }
    }

    @Test("too many parts to hear in one turn is refused, not partially delivered")
    func partCapRefusesRatherThanListeningToSome() async {
        let many = partsMessage(
            (0 ..< ChatAudio.maxPartsPerRequest + 1).map { _ in
                audioPart("https://example.invalid/a.wav")
            })
        let result = await ChatAudio.ingest(in: [many])
        // Bound checked before any OS call: still synchronous-visible as a refusal.
        switch result {
        case .success:
            Issue.record("over the part cap must refuse, not drop the tail quietly")
        case .failure(let failure):
            #expect(failure == .undecodableAudio)
        }
    }

    @Test("no audio in, request untouched, nothing disclosed")
    func textOnlyIsUntouched() async throws {
        let messages = [Message(role: "user", content: "plain")]
        let result = await ChatAudio.ingest(in: messages)
        switch result {
        case .success(let ingested):
            #expect(try sameWire(ingested.messages, messages))
            #expect(ingested.audioInput == nil)
        case .failure(let failure):
            Issue.record(
                "a text request must never be refused by audio ingestion (\(failure.rawValue))")
        }
    }

    @Test("the disclosure is snake_case on the wire and absent when there was no audio")
    func wireShape() throws {
        let completion = ChatCompletion(
            id: "chatcmpl-x", created: 1, model: "m",
            choices: [
                CompletionChoice(message: AssistantMessage(content: "hi"), finishReason: "stop")
            ],
            usage: Usage(input: 10, output: 2),
            audioInput: ChatAudioInput(
                parts: 1, transcribed: 1, engine: "apple-speech-analyzer", locales: ["zh_CN"],
                characters: 2))
        let json =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(completion)) as? [String: Any]
        let audio = json?["audio_input"] as? [String: Any]
        #expect(audio?["parts"] as? Int == 1)
        #expect(audio?["transcribed"] as? Int == 1)
        #expect(audio?["engine"] as? String == "apple-speech-analyzer")
        #expect(audio?["locales"] as? [String] == ["zh_CN"])
        #expect(audio?["characters"] as? Int == 2)
        #expect(json?["audioInput"] == nil, "the extension must follow the snake_case convention")

        let without = ChatCompletion(
            id: "chatcmpl-y", created: 1, model: "m",
            choices: [
                CompletionChoice(message: AssistantMessage(content: "hi"), finishReason: "stop")
            ],
            usage: Usage(input: 10, output: 2),
            audioInput: nil)
        let withoutJSON =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(without)) as? [String: Any]
        // Absent, not null: no audio in the request, so nothing to claim about it.
        #expect(withoutJSON?["audio_input"] == nil)
    }
}
