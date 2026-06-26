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
