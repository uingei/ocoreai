// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! DecisionsContractTests — `/v1/decisions` speaks sglang's contract, and only this suite makes
//! that a fact rather than a comment.
//!
//! ### The red each test was sampled against
//! Every rule asserted here is a rule the reference states, cited at its `file:line` in
//! `Wire/DecisionsWire.swift`, and each was sampled by running the offending body through the
//! decoder first. The load-bearing one is the unknown-field refusal: pydantic sets
//! `extra = "forbid"` on every decision model (`protocol.py:1654`, `:1603`, `:1610`, `:1629`,
//! `:1639`) because a silently dropped knob answers a *different question* than the one asked —
//! so a body carrying `"temprature"` must not decode into `temperature: 1.0`. The status codes are
//! sampled too: sglang overrides FastAPI's default 422 to 400 on this route and keeps 422 only for
//! `/v1/systemone` (`http_server.py:636-660`), so a schema failure that surfaces as a 500 is a red
//! here, not a difference of taste.
//!
//! ### Whose action changes on red
//! A contributor who widens a bound or renames a key without re-reading the upstream model, and a
//! contributor who adds a fourth question type without the refusal that stops a misspelled `type`
//! from being answered as some other type.

import Foundation
import Hummingbird
import Testing

@testable import ocoreai

@Suite("POST /v1/decisions — the sglang contract, field by field")
struct DecisionsContractTests {

    /// Reasons a body produced: empty when it decoded. Anything that is not a contract refusal is
    /// reported as a reason too, so an unexpected throw cannot pass as "no complaints".
    private static func reasons(_ json: String) -> [String] {
        do {
            _ = try DecisionsRequest.decode(Data(json.utf8))
            return []
        } catch let error as DecisionsValidationError {
            return error.reasons
        } catch {
            return ["<unexpected error: \(error)>"]
        }
    }

    private static func choiceQuestion(_ optionCount: Int, id: String = "q1") -> String {
        // An option is an OBJECT `{name, description?}` (`protocol.py:1602-1607`), so the braces are
        // part of the shape — writing the pair without them yields `"options":["name":"opt0"]`, which
        // is not JSON, and every assertion routed through this helper then judged a malformed body
        // instead of the rule it named.
        let options = (0 ..< optionCount).map { "{\"name\":\"opt\($0)\"}" }
        return
            "{\"id\":\"\(id)\",\"type\":\"choice\",\"question\":\"pick\","
            + "\"options\":[" + options.joined(separator: ",") + "]}"
    }

    private static func scoreQuestion(_ levelCount: Int, id: String = "q1") -> String {
        let levels = (0 ..< levelCount).map { "\"level\($0)\"" }
        return
            "{\"id\":\"\(id)\",\"type\":\"score\",\"question\":\"rate\","
            + "\"levels\":[" + levels.joined(separator: ",") + "]}"
    }

    private static func body(_ questions: String, _ extra: String = "") -> String {
        "{\"input\":\"the ticket says ship Friday\",\"questions\":[\(questions)]\(extra)}"
    }

    // MARK: - The happy path, asserted to exact values

    @Test("a valid request decodes to the values the caller sent, not to something compatible")
    func validRequestDecodesExactly() throws {
        let json = """
            {"input":"ship it?","model":"gemma-4-e2b-it-4bit","temperature":0.5,\
            "return_prompt_token_ids":true,"chat_template_kwargs":{"enable_thinking":false},\
            "questions":[{"id":"route","type":"choice","question":"which engine?",\
            "options":[{"name":"mlx"},{"name":"coreai","description":"ANE only"}]}]}
            """
        let request = try DecisionsRequest.decode(Data(json.utf8))
        #expect(request.input == .string("ship it?"))
        #expect(request.model == "gemma-4-e2b-it-4bit")
        #expect(request.temperature == 0.5)
        #expect(request.returnPromptTokenIds)
        #expect(request.promptFormatVersion == nil, "absent means whatever this server serves")
        #expect(request.images.isEmpty)
        #expect(request.chatTemplateKwargs == ["enable_thinking": .bool(false)])
        #expect(
            request.questions
                == [
                    .choice(
                        id: "route", question: .string("which engine?"),
                        options: [
                            DecisionOption(name: "mlx", description: nil),
                            DecisionOption(name: "coreai", description: .string("ANE only")),
                        ])
                ]
        )
    }

    @Test("defaults are the reference's defaults")
    func defaultsMatchUpstream() throws {
        let request = try DecisionsRequest.decode(Data(Self.body(Self.choiceQuestion(2)).utf8))
        // `temperature: float = 1.0` (`protocol.py:1660`), `return_prompt_token_ids: bool = False`
        // (`:1665`), `images` and `chat_template_kwargs` default to empty (`:1657,1659`).
        #expect(request.temperature == 1.0)
        #expect(!request.returnPromptTokenIds)
        #expect(request.images.isEmpty)
        #expect(request.chatTemplateKwargs.isEmpty)
        #expect(request.model == nil, "nil defers to the served default, as a chat request does")
    }

    @Test("the suite's own builders are sound — a builder that emits garbage judges nothing")
    func buildersAreSound() throws {
        // This suite's premises are two string builders. The first version of `choiceQuestion`
        // emitted `"options":["name":"opt0"]` — no braces, not JSON — and 11 assertions quietly read
        // "body must be a JSON object" as if it were a verdict about bounds and option names. So the
        // builders get asserted, at both a middle size and the boundary a bound test relies on.
        let two = try DecisionsRequest.decode(Data(Self.body(Self.choiceQuestion(2)).utf8))
        guard case .choice(_, _, let options) = two.questions.first else {
            Issue.record("the composed choice body must decode as a choice question")
            return
        }
        #expect(options.map(\.name) == ["opt0", "opt1"])
        let maxed = try DecisionsRequest.decode(
            Data(Self.body(Self.choiceQuestion(DecisionsContract.maxChoiceOptions)).utf8))
        #expect(maxed.questions.first?.labelCount == DecisionsContract.maxChoiceOptions)
        let levels = try DecisionsRequest.decode(
            Data(Self.body(Self.scoreQuestion(3)).utf8))
        #expect(
            levels.questions.first?.labelCount == 3,
            "a score question's levels are plain texts, so this helper was already sound")
    }

    @Test("all three question types decode, and each keeps its own shape")
    func everyQuestionTypeDecodes() throws {
        let json = Self.body(
            """
            {"id":"a","type":"yes_no","question":"safe?"},\
            {"id":"b","type":"score","question":"quality","levels":["bad","ok","good"]},\
            {"id":"c","type":"choice","question":"owner","options":[{"name":"core"},{"name":"ui"}]}
            """
        )
        let request = try DecisionsRequest.decode(Data(json.utf8))
        #expect(request.questions.map { $0.typeWord } == ["yes_no", "score", "choice"])
        #expect(request.questions.map { $0.id } == ["a", "b", "c"])
        guard case .score(_, _, let levels) = request.questions[1] else {
            Issue.record("the second question must be a score question")
            return
        }
        #expect(levels == [.string("bad"), .string("ok"), .string("good")])
    }

    // MARK: - Unknown fields, refused by name

    @Test("an unknown top-level field is refused by name, never dropped")
    func unknownTopLevelField() {
        // The sampled failure: `"temprature"` must not become `temperature: 1.0` in silence.
        let found = Self.reasons(
            Self.body(Self.choiceQuestion(2), ",\"temprature\":0.2"))
        #expect(found == ["unknown field 'temprature'"])
    }

    @Test("an unknown field inside a question is refused by name")
    func unknownQuestionField() {
        let found = Self.reasons(
            """
            {"input":"x","questions":[{"id":"q","type":"yes_no","question":"ok?","yes_label":"yep"}]}
            """
        )
        #expect(found == ["question 0: unknown field 'yes_label'"])
    }

    @Test("every key the contract accepts is accepted, and only those")
    func acceptedKeyTraversal() {
        // Traversal, not a spot check: the accepted set and the contract's key set must be the same
        // set, or this test would keep passing after a key was renamed on one side only.
        let accepted: [String: String] = [
            "input": "\"fresh\"",
            "questions": "[{\"id\":\"q\",\"type\":\"yes_no\",\"question\":\"ok?\"}]",
            "model": "\"gemma\"",
            "temperature": "0.5",
            "chat_template_kwargs": "{\"k\":1}",
            "prompt_format_version": "1",
            "return_prompt_token_ids": "true",
            "images": "[]",
        ]
        #expect(Set(accepted.keys) == DecisionsContract.requestKeys)
        for (key, value) in accepted {
            let found = Self.reasons(
                Self.body(
                    "{\"id\":\"q\",\"type\":\"yes_no\",\"question\":\"ok?\"}",
                    ",\"\(key)\":\(value)")
            )
            .filter { $0.contains("unknown field") }
            #expect(found.isEmpty, "'\(key)' is a contract key and must not be refused: \(found)")
        }
    }

    // MARK: - Bounds and label rules

    @Test("options and levels are bounded at the reference's bounds, both ends")
    func boundsAreTheReferenceBounds() {
        let minLabels = DecisionsContract.minLabels
        #expect(minLabels == 2, "one label is not a decision (`protocol.py:1614`)")
        #expect(DecisionsContract.maxChoiceOptions == 26, "options are labeled A–Z")
        #expect(DecisionsContract.maxScoreLevels == 10, "levels are labeled 0–9")

        #expect(Self.reasons(Self.body(Self.choiceQuestion(2))).isEmpty)
        #expect(
            Self.reasons(Self.body(Self.choiceQuestion(DecisionsContract.maxChoiceOptions))).isEmpty
        )
        #expect(
            Self.reasons(Self.body(Self.choiceQuestion(DecisionsContract.maxChoiceOptions + 1)))
                == [
                    "question 'q1': 'options' must be an array of 2 to 26 options"
                ])
        #expect(
            Self.reasons(Self.body(Self.choiceQuestion(1)))
                == ["question 'q1': 'options' must be an array of 2 to 26 options"])

        #expect(
            Self.reasons(Self.body(Self.scoreQuestion(DecisionsContract.maxScoreLevels))).isEmpty)
        #expect(
            Self.reasons(Self.body(Self.scoreQuestion(DecisionsContract.maxScoreLevels + 1)))
                == ["question 'q1': 'levels' must be an array of 2 to 10 levels"])
        #expect(
            Self.reasons(Self.body(Self.scoreQuestion(1)))
                == ["question 'q1': 'levels' must be an array of 2 to 10 levels"])
    }

    @Test("a blank name, a control character, or a folded duplicate option name is refused")
    func optionNameRules() {
        // `check_option_names` (`protocol.py:1564-1579`): each option is rendered as one prompt
        // line, so those three cases would answer a question the caller did not write.
        #expect(
            Self.reasons(
                Self.body(
                    """
                    {"id":"q1","type":"choice","question":"pick","options":[{"name":"a"},{"name":"  "}]}
                    """
                )) == ["question 'q1': option names must be nonempty"])
        // The reason quotes the name verbatim, exactly as the "repeats another option" reason below
        // does, so the string it quotes contains the real newline the caller sent — JSON escapes it on
        // the wire, and the two messages about a name must not disagree about whether to escape.
        #expect(
            Self.reasons(
                Self.body(
                    """
                    {"id":"q1","type":"choice","question":"pick","options":[{"name":"a\\nb"},{"name":"a"}]}
                    """
                )) == [
                    "question 'q1': option name 'a\nb' must not contain control or line break characters"
                ])
        // Case and edge whitespace are not part of a name: `seen` keys on `strip().casefold()`.
        let folded = Self.reasons(
            Self.body(
                """
                {"id":"q1","type":"choice","question":"pick","options":[{"name":" Yes "},{"name":"yes"}]}
                """
            ))
        #expect(folded == ["question 'q1': option name 'yes' repeats another option"])
    }

    @Test("a repeated question id is refused — it would answer two questions with one entry")
    func duplicateQuestionIDs() {
        let found = Self.reasons(
            Self.body(
                """
                {"id":"same","type":"yes_no","question":"first?"},\
                {"id":"same","type":"yes_no","question":"second?"}
                """
            ))
        #expect(found == ["question id 'same' repeats another question"])
    }

    @Test("`input` and `question` must be present and non-blank")
    func requiredTexts() {
        let noInput = Self.reasons(
            "{\"questions\":[{\"id\":\"q\",\"type\":\"yes_no\",\"question\":\"ok?\"}]}")
        #expect(noInput == ["'input' is required"])
        #expect(
            Self.reasons(
                "{\"input\":\"   \",\"questions\":[{\"id\":\"q\",\"type\":\"yes_no\",\"question\":\"ok?\"}]}"
            ) == ["'input' must not be blank"])
        #expect(
            Self.reasons(
                "{\"input\":\"x\",\"questions\":[{\"id\":\"q\",\"type\":\"yes_no\",\"question\":\"  \"}]}"
            ) == ["question 'q': 'question' must be non-blank text"])
        // An empty container is blank too, because `DecisionText` may be `dict` or `list`
        // (`protocol.py:1583-1585`) and an empty one decides nothing.
        #expect(
            Self.reasons(
                "{\"input\":[],\"questions\":[{\"id\":\"q\",\"type\":\"yes_no\",\"question\":\"ok?\"}]}"
            ) == ["'input' must not be blank"])
    }

    @Test("temperature keeps the reference's domain: a number, greater than 0")
    func temperatureDomain() {
        #expect(
            Self.reasons(Self.body(Self.choiceQuestion(2), ",\"temperature\":0"))
                == ["'temperature' must be greater than 0 and finite"])
        #expect(
            Self.reasons(Self.body(Self.choiceQuestion(2), ",\"temperature\":-1"))
                == ["'temperature' must be greater than 0 and finite"])
        #expect(
            Self.reasons(Self.body(Self.choiceQuestion(2), ",\"temperature\":\"hot\""))
                == ["'temperature' must be a number"])
        #expect(Self.reasons(Self.body(Self.choiceQuestion(2), ",\"temperature\":2000")).isEmpty)
    }

    @Test("a misspelled type is refused, not answered as some other type")
    func discriminatorIsClosed() {
        let found = Self.reasons(
            """
            {"input":"x","questions":[{"id":"q","type":"yesno","question":"ok?"}]}
            """
        )
        #expect(found == ["question 0: 'type' must be choice, score or yes_no"])
    }

    @Test("malformed JSON is a contract refusal, not a crash and not a 500")
    func malformedBody() {
        #expect(Self.reasons("{not json") == ["body must be a JSON object"])
        #expect(Self.reasons("[1,2]") == ["body must be a JSON object"])
    }

    // MARK: - One pass, all reasons

    @Test("every reason arrives at once, as the reference's detail list does")
    func allReasonsAtOnce() {
        let found = Self.reasons(
            "{\"input\":\"\",\"questions\":[],\"temprature\":1,\"model\":7}")
        #expect(
            found == [
                "unknown field 'temprature'",
                "'input' must not be blank",
                "'questions' must be an array of at least 1 question",
                "'model' must be a string",
            ],
            "a client fixing one request learns all of it in one round trip")
    }

    // MARK: - Status codes

    @Test("a contract refusal is a 400 and a missing read is a 501, as the reference answers them")
    func statusCodes() {
        // sglang overrides FastAPI's default 422 to 400 for this route and keeps 422 only for
        // `/v1/systemone` (`http_server.py:636-660`); an unhandled throw would reach 500 instead.
        #expect(AppError.invalidRequest("x").status == .badRequest)
        #expect(AppError.decisionsUnavailable("x").status == .notImplemented)
        #expect(
            AppError.decisionsUnavailable("named cause").description.contains("named cause") == true
        )
    }

    @Test("the refusal says how much went unmeasured, counted the way a scorer would count it")
    func refusalCountsItsLabels() throws {
        // The 501's whole value over a bare 501 is naming what is missing, and it names a count; a
        // count that drifts from the request makes the refusal a claim again.
        let json = Self.body(
            """
            {"id":"a","type":"yes_no","question":"safe?"},\
            {"id":"b","type":"score","question":"quality","levels":["bad","ok","good"]},\
            {"id":"c","type":"choice","question":"owner","options":[{"name":"core"},{"name":"ui"},{"name":"docs"}]}
            """
        )
        let request = try DecisionsRequest.decode(Data(json.utf8))
        // 2 (yes/no is two labels by definition) + 3 levels + 3 options.
        #expect(request.questions.map(\.labelCount) == [2, 3, 3])
        #expect(DecisionsHandler.labelCount(for: request) == 8)
        var refusal: AppError?
        do {
            _ = try DecisionsHandler.handle(request)
            Issue.record("a validated request must be refused by this build, not answered")
        } catch let error as AppError {
            refusal = error
        }
        #expect(refusal?.status == .notImplemented)
        let message = refusal?.description ?? ""
        #expect(
            message.contains("3 question(s)") && message.contains("8 label(s)"),
            "the refusal counts what it could not measure, off this request: \(message)")
        #expect(
            message.contains("Decision refused"),
            "that prefix is what a client greps, so it is a contract line: \(message)")
    }
}
