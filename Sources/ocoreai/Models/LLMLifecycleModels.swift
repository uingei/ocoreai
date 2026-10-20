// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LLMLifecycleModels.swift — DTOs for P5 LLM lifecycle endpoints

import Foundation
import HTTPTypes

struct TrainRequest: Decodable {
    var model: String
    var trainingData: TrainingDatasetInput
    var validationData: TrainingDatasetInput?
    var lora: LoRAConfig = .init()
    var hyperparams: TrainHyperparams = .init()

    enum CodingKeys: String, CodingKey {
        case model, trainingData, validationData, lora, hyperparams
    }

    init(
        model: String,
        trainingData: TrainingDatasetInput,
        validationData: TrainingDatasetInput? = nil,
        lora: LoRAConfig = .init(),
        hyperparams: TrainHyperparams = .init(),
    ) {
        self.model = model
        self.trainingData = trainingData
        self.validationData = validationData
        self.lora = lora
        self.hyperparams = hyperparams
    }

    /// Only `model` and `training_data` are required; `lora` / `hyperparams` carry whole-object
    /// defaults, so a body that omits them must decode rather than 400 (the synthesized decoder
    /// required both keys — a default on a non-Optional property is not optionality on the wire).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        trainingData = try container.decode(TrainingDatasetInput.self, forKey: .trainingData)
        validationData = try container.decodeIfPresent(
            TrainingDatasetInput.self, forKey: .validationData)
        lora = try container.decodeIfPresent(LoRAConfig.self, forKey: .lora) ?? LoRAConfig()
        hyperparams =
            try container.decodeIfPresent(TrainHyperparams.self, forKey: .hyperparams)
            ?? TrainHyperparams()
    }

    enum TrainingDatasetInput: Decodable {
        case inline([String])
        case file(trainPath: String, validationPath: String?)

        enum CodingKeys: String, CodingKey { case inline, trainPath, validationPath }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.inline) {
                self = try .inline(container.decode([String].self, forKey: .inline))
            } else if container.contains(.trainPath) {
                let trainPath = try container.decode(String.self, forKey: .trainPath)
                let vp = try container.decodeIfPresent(String.self, forKey: .validationPath)
                self = .file(trainPath: trainPath, validationPath: vp)
            } else {
                self = try .inline([String](from: decoder))
            }
        }
    }

    struct LoRAConfig: Decodable {
        var rank: Int = 8
        var scale: Float = 20.0
        var numLayers: Int = 4

        enum CodingKeys: String, CodingKey { case rank, scale, numLayers }

        init(rank: Int = 8, scale: Float = 20.0, numLayers: Int = 4) {
            self.rank = rank
            self.scale = scale
            self.numLayers = numLayers
        }

        /// Every field is optional on the wire (the defaults above are the contract), so none may
        /// be required by the decoder — `{"lora":{}}` must decode, not 400. Declaring `init(from:)`
        /// also replaces the synthesized memberwise init, hence the explicit one above.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rank = try container.decodeIfPresent(Int.self, forKey: .rank) ?? 8
            scale = try container.decodeIfPresent(Float.self, forKey: .scale) ?? 20.0
            numLayers = try container.decodeIfPresent(Int.self, forKey: .numLayers) ?? 4
        }
    }

    struct TrainHyperparams: Decodable {
        var learningRate: Float = 0.00001
        var batchSize: Int = 4
        var iterations: Int = 1000
        var stepsPerReport: Int = 10
        var stepsPerEval: Int = 100
        var validationBatches: Int = 10
        var saveEvery: Int = 200

        enum CodingKeys: String, CodingKey {
            case learningRate = "learning_rate"
            case batchSize = "batch_size"
            case iterations
            case stepsPerReport = "steps_per_report"
            case stepsPerEval = "steps_per_eval"
            case validationBatches = "validation_batches"
            case saveEvery = "save_every"
        }

        init(
            learningRate: Float = 0.00001,
            batchSize: Int = 4,
            iterations: Int = 1000,
            stepsPerReport: Int = 10,
            stepsPerEval: Int = 100,
            validationBatches: Int = 10,
            saveEvery: Int = 200,
        ) {
            self.learningRate = learningRate
            self.batchSize = batchSize
            self.iterations = iterations
            self.stepsPerReport = stepsPerReport
            self.stepsPerEval = stepsPerEval
            self.validationBatches = validationBatches
            self.saveEvery = saveEvery
        }

        /// Same rule as ``LoRAConfig``: seven defaults on the type mean seven optional keys on
        /// the wire, and the synthesized decoder would have required all seven.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            learningRate =
                try container.decodeIfPresent(Float.self, forKey: .learningRate) ?? 0.00001
            batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? 4
            iterations = try container.decodeIfPresent(Int.self, forKey: .iterations) ?? 1000
            stepsPerReport = try container.decodeIfPresent(Int.self, forKey: .stepsPerReport) ?? 10
            stepsPerEval = try container.decodeIfPresent(Int.self, forKey: .stepsPerEval) ?? 100
            validationBatches =
                try container.decodeIfPresent(Int.self, forKey: .validationBatches) ?? 10
            saveEvery = try container.decodeIfPresent(Int.self, forKey: .saveEvery) ?? 200
        }
    }
}

struct EvalRequest: Decodable {
    var model: String
    var dataset: [String]
    var batchSize: Int = 4
    var maxBatches: Int = 0

    enum CodingKeys: String, CodingKey {
        case model, dataset
        case batchSize = "batch_size"
        case maxBatches = "max_batches"
    }

    /// `batch_size` / `max_batches` are optional on the wire, so they are decoded with
    /// `decodeIfPresent` — the same defect `DownloadModelRequest.useLatest` had (measured 10-20:
    /// a property default does not relax the synthesized decoder, it only documents the intent).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        dataset = try container.decode([String].self, forKey: .dataset)
        batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? 4
        maxBatches = try container.decodeIfPresent(Int.self, forKey: .maxBatches) ?? 0
    }

    init(model: String, dataset: [String], batchSize: Int = 4, maxBatches: Int = 0) {
        self.model = model
        self.dataset = dataset
        self.batchSize = batchSize
        self.maxBatches = maxBatches
    }
}

struct TrainProgressChunk: Encodable {
    var type: String
    var iteration: Int
    var trainingLoss: Float?
    var validationLoss: Float?
    var iterationsPerSec: Double?
    var tokensPerSec: Double?
    var checkpointPath: String?
    var message: String
    var timestamp: Int64
}

struct TrainSummary: Encodable {
    var success: Bool
    var iterationsCompleted: Int
    var finalTrainLoss: Float?
    var finalValidLoss: Float?
    var adapterPath: String?
    var durationSeconds: Double
    var error: String?
}

struct EvalSummary: Encodable {
    var loss: Float
    var perplexity: Float
    var batchesEvaluated: Int
    var durationSeconds: Double
}
