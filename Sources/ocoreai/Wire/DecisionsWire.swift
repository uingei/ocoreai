// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DecisionsWire.swift — the Jev / System 1 decision contract, in one home.
///
/// ### Which published shape, and why that one
/// The axis exists twice. `POST /v1/decisions` answers typed choice / score / yes-no questions
/// by scoring single-token answer labels at the answer position and needs **no special
/// checkpoint** — any generation model with a chat template can answer
/// (`~/references/sglang/docs/docs/supported-models/decision_models.mdx:5`), which is our
/// situation exactly: open checkpoints on MLX. `POST /v1/systemone` is diffusion-native and needs
/// a served canvas plus a diffusion checkpoint
/// (`~/references/vllm/examples/features/structured_diffusion/README.md:10-13,47`); our registry
/// has no diffusion architecture, so that route is not registered — a route row is a promise,
/// since it renders onto `/v1/capabilities` and `/openapi.json`.
///
/// ### What consistency is pinned to
/// Field names, defaults, bounds, the non-blank rule, the option-name rule and the refuse-unknown-
/// fields-by-name rule all mirror sglang's models at
/// `~/references/sglang/python/sglang/srt/entrypoints/openai/protocol.py:1554-1700`, routed at
/// `http_server.py:2048`; each rule below cites its line. The **status** is part of the contract:
/// sglang overrides FastAPI's default 422 to 400 on this route and keeps 422 only for
/// `/v1/systemone` (`http_server.py:636-660`), so a schema failure here is a 400 and never a 500.
/// Reason *wording* is ours — pydantic's text carries Python internals, and sglang scrubs the
/// same class of leak on `/v1/messages` for exactly that reason (`http_server.py:637-639`).
///
/// ### What is deliberately absent
/// Response DTOs. A probability requires logits published at the answer position, and only the
/// CoreAI route publishes logits (`Engine/EngineLogprobs.swift:22` — `#if canImport(CoreAI)`,
/// `@available(macOS 27.0, *)`), which is why `POST /v1/completions` with `logprobs` answers 501 on
/// the delivery platform. `DecisionsHandler` therefore refuses every scoring request naming that
/// prerequisite; inventing a number is the one failure mode this axis cannot afford
/// (`docs/agent/systemone-decisions.md` § the cheapest honest slice, item 5), so an answer type
/// nothing can fill does not get written.

import Foundation

// MARK: - JSON tree

/// A JSON value, held structurally so a blank check and an unknown-key refusal see what the
/// client actually sent. sglang types a decision string as `str | dict | list`
/// (`protocol.py:1583`) and treats an empty container as blank (`:1554-1555`), so this is a tree
/// rather than a `String`, and it is `Equatable` so a test can assert an exact value.
enum DecisionJSON: Sendable, Equatable, Decodable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([DecisionJSON])
    case object([String: DecisionJSON])

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() {
            self = .null
        } else if let value = try? box.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? box.decode(Int.self) {
            self = .int(value)
        } else if let value = try? box.decode(Double.self) {
            self = .double(value)
        } else if let value = try? box.decode(String.self) {
            self = .string(value)
        } else if let value = try? box.decode([DecisionJSON].self) {
            self = .array(value)
        } else if let value = try? box.decode([String: DecisionJSON].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    /// `str | dict | list`, the only shapes a decision field may hold (`protocol.py:1583`).
    var isDecisionText: Bool {
        switch self {
        case .string, .array, .object: return true
        default: return false
        }
    }

    /// Mirrors `is_blank_decision_text` (`protocol.py:1554-1555`): a string is blank when its
    /// trim is empty, a container when it holds nothing. `null` and a number are not text at all,
    /// and the caller refuses those as the wrong type instead of calling them blank.
    var isBlankDecisionText: Bool {
        switch self {
        case .string(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let items): return items.isEmpty
        case .object(let pairs): return pairs.isEmpty
        default: return true
        }
    }

    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value == value.rounded(): return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [DecisionJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var objectValue: [String: DecisionJSON]? {
        if case .object(let pairs) = self { return pairs }
        return nil
    }
}

// MARK: - Contract constants

/// Bounds and key sets of `/v1/decisions`, one line cite each.
enum DecisionsContract {
    /// Options are labeled A–Z in order, so at most 26 (`protocol.py:1614`).
    static let maxChoiceOptions = 26
    /// Score levels are labeled 0–9 in order, so at most 10 (`protocol.py:1634`).
    static let maxScoreLevels = 10
    /// Both families floor at two labels: one label is not a decision (`protocol.py:1614,1634`).
    static let minLabels = 2

    /// Top-level keys, from `DecisionRequest`'s fields (`protocol.py:1653-1666`). Unknown keys are
    /// refused by name, because `model_config = ConfigDict(extra="forbid")` exists so a silently
    /// dropped knob cannot change the answers while looking honored (`:1654`).
    static let requestKeys: Set<String> = [
        "input", "questions", "model", "temperature", "chat_template_kwargs",
        "prompt_format_version", "return_prompt_token_ids", "images",
    ]

    /// Per-question keys, from the three question models (`protocol.py:1609-1648`). Each also
    /// carries `extra="forbid"`: "misspelled keys inside a question would otherwise answer a
    /// different question" (`systemone/protocol.py:34`).
    static let questionKeys: [String: Set<String>] = [
        "choice": ["id", "type", "question", "options"],
        "score": ["id", "type", "question", "levels"],
        "yes_no": ["id", "type", "question", "yes", "no"],
    ]
}

// MARK: - Validation error

/// Every reason a body fails the contract, collected in one pass. sglang answers a schema failure
/// with the whole detail list rather than the first complaint (`http_server.py:636-660`), so a
/// client fixing a request learns all of it at once.
struct DecisionsValidationError: Error, CustomStringConvertible {
    let reasons: [String]
    var description: String { reasons.joined(separator: "; ") }
}

// MARK: - Request

/// One answer label a caller offered, with what it renders as in the prompt.
struct DecisionOption: Sendable, Equatable {
    let name: String
    /// `description` is optional text (`protocol.py:1606`); nil means the name alone is the line.
    let description: DecisionJSON?
}

/// One question, after the discriminator is resolved. The `id` is the answer map's key, so it is
/// carried on every case rather than alongside them.
enum DecisionQuestion: Sendable, Equatable {
    case choice(id: String, question: DecisionJSON, options: [DecisionOption])
    case score(id: String, question: DecisionJSON, levels: [DecisionJSON])
    case yesNo(id: String, question: DecisionJSON, yes: DecisionJSON?, no: DecisionJSON?)

    var id: String {
        switch self {
        case .choice(let id, _, _), .score(let id, _, _), .yesNo(let id, _, _, _): return id
        }
    }

    /// How many answer labels this question offers. A yes/no is two by definition, which is why the
    /// count lives on the question rather than in whatever is reporting it: a refusal that says how
    /// much went unmeasured and a future scorer must not count labels two different ways.
    var labelCount: Int {
        switch self {
        case .choice(_, _, let options): return options.count
        case .score(_, _, let levels): return levels.count
        case .yesNo: return 2
        }
    }

    /// The wire word for the type, so a refusal and the answer map agree on one spelling.
    var typeWord: String {
        switch self {
        case .choice: return "choice"
        case .score: return "score"
        case .yesNo: return "yes_no"
        }
    }
}

/// A validated `POST /v1/decisions` body. Built only by ``decode(_:)``, because every field's
/// legality is the contract: an instance of this type *is* a request that passed it.
struct DecisionsRequest: Sendable, Equatable {
    let input: DecisionJSON
    let questions: [DecisionQuestion]
    /// Optional with a server-side default upstream (`protocol.py:1666`); nil defers to the
    /// served default model, exactly as a chat request that omits `model` does.
    let model: String?
    /// `1.0` when absent; scales option probabilities only, never label mass (`protocol.py:1660`).
    let temperature: Double
    let chatTemplateKwargs: [String: DecisionJSON]
    /// Pins the server-owned prompt wording; a served version that differs is refused
    /// (`protocol.py:1664-1665`). nil means "whatever this server serves".
    let promptFormatVersion: Int?
    let returnPromptTokenIds: Bool
    let images: [DecisionJSON]

    /// Decode and validate in one pass, collecting every reason. Throws
    /// ``DecisionsValidationError`` — which the handler turns into a 400 naming each reason.
    static func decode(_ body: Data) throws -> DecisionsRequest {
        let tree: DecisionJSON
        do {
            tree = try JSONDecoder().decode(DecisionJSON.self, from: body)
        } catch {
            throw DecisionsValidationError(reasons: ["body must be a JSON object"])
        }
        guard let fields = tree.objectValue else {
            throw DecisionsValidationError(reasons: ["body must be a JSON object"])
        }
        var reasons: [String] = []

        for key in fields.keys.sorted() where !DecisionsContract.requestKeys.contains(key) {
            reasons.append("unknown field '\(key)'")
        }

        var input: DecisionJSON = .null
        if let value = fields["input"] {
            if !value.isDecisionText {
                reasons.append("'input' must be a string, an object or an array")
            } else if value.isBlankDecisionText {
                reasons.append("'input' must not be blank")
            } else {
                input = value
            }
        } else {
            reasons.append("'input' is required")
        }

        let questions = decodeQuestions(fields["questions"], into: &reasons)

        var temperature = 1.0
        if let value = fields["temperature"] {
            // `gt=0, allow_inf_nan=False` (`protocol.py:1660`): 0 divides later, and a NaN or
            // infinity would answer with a probability no client can compare against another.
            if let candidate = value.doubleValue {
                if candidate > 0 && candidate.isFinite {
                    temperature = candidate
                } else {
                    reasons.append("'temperature' must be greater than 0 and finite")
                }
            } else {
                reasons.append("'temperature' must be a number")
            }
        }

        var kwargs: [String: DecisionJSON] = [:]
        if let value = fields["chat_template_kwargs"] {
            if let pairs = value.objectValue {
                kwargs = pairs
            } else {
                reasons.append("'chat_template_kwargs' must be an object")
            }
        }

        var promptFormatVersion: Int?
        if let value = fields["prompt_format_version"], value != .null {
            if let candidate = value.intValue {
                promptFormatVersion = candidate
            } else {
                reasons.append("'prompt_format_version' must be an integer or null")
            }
        }

        var returnPromptTokenIds = false
        if let value = fields["return_prompt_token_ids"] {
            if let flag = value.boolValue {
                returnPromptTokenIds = flag
            } else {
                reasons.append("'return_prompt_token_ids' must be a boolean")
            }
        }

        var images: [DecisionJSON] = []
        if let value = fields["images"] {
            if let items = value.arrayValue {
                images = items
            } else {
                reasons.append("'images' must be an array")
            }
        }

        var model: String?
        if let value = fields["model"] {
            if let name = value.stringValue {
                model = name
            } else {
                reasons.append("'model' must be a string")
            }
        }

        guard reasons.isEmpty else { throw DecisionsValidationError(reasons: reasons) }
        return DecisionsRequest(
            input: input,
            questions: questions,
            model: model,
            temperature: temperature,
            chatTemplateKwargs: kwargs,
            promptFormatVersion: promptFormatVersion,
            returnPromptTokenIds: returnPromptTokenIds,
            images: images
        )
    }

    /// `questions` is a list with `min_length=1`, discriminated on `type` (`protocol.py:1658,1649`).
    private static func decodeQuestions(
        _ field: DecisionJSON?, into reasons: inout [String]
    ) -> [DecisionQuestion] {
        guard let raw = field?.arrayValue else {
            reasons.append("'questions' must be an array of at least 1 question")
            return []
        }
        guard !raw.isEmpty else {
            reasons.append("'questions' must be an array of at least 1 question")
            return []
        }
        var questions: [DecisionQuestion] = []
        var seenIDs: Set<String> = []
        for (index, item) in raw.enumerated() {
            guard let fields = item.objectValue else {
                reasons.append("question \(index): must be an object")
                continue
            }
            guard let typeWord = fields["type"]?.stringValue else {
                reasons.append("question \(index): 'type' must be choice, score or yes_no")
                continue
            }
            guard let allowedKeys = DecisionsContract.questionKeys[typeWord] else {
                reasons.append("question \(index): 'type' must be choice, score or yes_no")
                continue
            }
            for key in fields.keys.sorted() where !allowedKeys.contains(key) {
                reasons.append("question \(index): unknown field '\(key)'")
            }
            let id: String
            if let candidate = fields["id"]?.stringValue,
                !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                id = candidate
            } else {
                reasons.append("question \(index): 'id' must not be blank")
                continue
            }
            // Question ids are the answer map's keys, so a repeat would answer two questions with
            // one entry (`protocol.py:1672-1680`).
            if seenIDs.contains(id) {
                reasons.append("question id '\(id)' repeats another question")
                continue
            }
            seenIDs.insert(id)

            guard let question = fields["question"] else {
                reasons.append("question '\(id)': 'question' is required")
                continue
            }
            guard question.isDecisionText, !question.isBlankDecisionText else {
                reasons.append("question '\(id)': 'question' must be non-blank text")
                continue
            }

            switch typeWord {
            case "choice":
                if let options = decodeOptions(fields["options"], id: id, into: &reasons) {
                    questions.append(.choice(id: id, question: question, options: options))
                }
            case "score":
                if let levels = decodeLevels(fields["levels"], id: id, into: &reasons) {
                    questions.append(.score(id: id, question: question, levels: levels))
                }
            default:
                let yes = fields["yes"]
                let no = fields["no"]
                var labelsAreSound = true
                for (label, value) in [("yes", yes), ("no", no)] {
                    if let value, !value.isDecisionText || value.isBlankDecisionText {
                        reasons.append("question '\(id)': '\(label)' must be non-blank text")
                        labelsAreSound = false
                    }
                }
                if labelsAreSound {
                    questions.append(.yesNo(id: id, question: question, yes: yes, no: no))
                }
            }
        }
        return questions
    }

    /// `options` is 2…26 entries of `{name, description?}` (`protocol.py:1602-1625`).
    private static func decodeOptions(
        _ field: DecisionJSON?, id: String, into reasons: inout [String]
    ) -> [DecisionOption]? {
        guard let raw = field?.arrayValue else {
            reasons.append(
                "question '\(id)': 'options' must be an array of \(DecisionsContract.minLabels) to \(DecisionsContract.maxChoiceOptions) options"
            )
            return nil
        }
        guard raw.count >= DecisionsContract.minLabels,
            raw.count <= DecisionsContract.maxChoiceOptions
        else {
            reasons.append(
                "question '\(id)': 'options' must be an array of \(DecisionsContract.minLabels) to \(DecisionsContract.maxChoiceOptions) options"
            )
            return nil
        }
        var options: [DecisionOption] = []
        var seenNames: Set<String> = []
        for item in raw {
            guard let fields = item.objectValue, let name = fields["name"]?.stringValue else {
                reasons.append("question '\(id)': every option needs a string 'name'")
                continue
            }
            for key in fields.keys.sorted() where key != "name" && key != "description" {
                reasons.append("question '\(id)': option has unknown field '\(key)'")
            }
            if let description = fields["description"],
                !description.isDecisionText || description.isBlankDecisionText
            {
                reasons.append("question '\(id)': option 'description' must be non-blank text")
            }
            // `check_option_names` (`protocol.py:1564-1579`): names become one prompt line each,
            // so a blank name, a control character, or two names that fold together would make
            // the rendered lines ambiguous. Case and edge whitespace are not part of a name.
            let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if folded.isEmpty {
                reasons.append("question '\(id)': option names must be nonempty")
                continue
            }
            if containsLineBreakingControl(name) {
                reasons.append(
                    "question '\(id)': option name '\(name)' must not contain control or line break characters"
                )
                continue
            }
            if seenNames.contains(folded) {
                reasons.append("question '\(id)': option name '\(name)' repeats another option")
                continue
            }
            seenNames.insert(folded)
            options.append(DecisionOption(name: name, description: fields["description"]))
        }
        guard options.count == raw.count else { return nil }
        return options
    }

    /// `levels` is 2…10 non-blank texts, labeled 0–9 in order (`protocol.py:1627-1635`).
    private static func decodeLevels(
        _ field: DecisionJSON?, id: String, into reasons: inout [String]
    ) -> [DecisionJSON]? {
        guard let raw = field?.arrayValue,
            raw.count >= DecisionsContract.minLabels,
            raw.count <= DecisionsContract.maxScoreLevels
        else {
            reasons.append(
                "question '\(id)': 'levels' must be an array of \(DecisionsContract.minLabels) to \(DecisionsContract.maxScoreLevels) levels"
            )
            return nil
        }
        for level in raw where !level.isDecisionText || level.isBlankDecisionText {
            reasons.append("question '\(id)': every level must be non-blank text")
            return nil
        }
        return raw
    }

    /// Unicode categories Cc, Zl and Zp (`protocol.py:1572-1576`): C0/C1 controls, line
    /// separator, paragraph separator. A newline in a name would end the option's prompt line.
    private static func containsLineBreakingControl(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value <= 0x1F || value == 0x7F || value == 0x2028 || value == 0x2029
                || (value >= 0x80 && value <= 0x9F)
            {
                return true
            }
        }
        return false
    }
}
