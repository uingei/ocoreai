// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LLMLifecycleHandler.swift — LoRA fine-tuning + evaluation via MLX

#if mlx

	import Foundation
	import HTTPTypes
	import Hummingbird
	import Logging
	import MLXLLM
	import MLXLMCommon
	import MLXNN
	import MLXOptimizers
	import NIOCore

	// MARK: - Train Handler (SSE Stream — ChatHandler pattern)

	func trainHandler(
		request: TrainRequest,
		enginePool: EnginePool,
		logger: Logger,
	) async throws -> Response {
		let stream = AsyncStream<ByteBuffer> { continuation in
			Task {
				do {
					try await _doTrain(
						request: request, enginePool: enginePool,
						logger: logger, continuation: continuation,
					)
				} catch {
					_ = yieldSSE(
						TrainProgressChunk(
							type: "error", iteration: 0, trainingLoss: nil, validationLoss: nil,
							iterationsPerSec: nil, tokensPerSec: nil, checkpointPath: nil,
							message: "Training failed: \(error.localizedDescription)",
							timestamp: Int64(Date().timeIntervalSince1970),
						), to: continuation,
					)
				}
				continuation.finish()
			}
		}
		return Response(
			status: .ok,
			headers: SSEHeaders,
			body: .init(asyncSequence: stream),
		)
	}

	private struct TrainResult {
		var success: Bool; var iterations: Int; var trainLoss: Float?; var validLoss: Float?; var adapterPath: String?; var errMsg: String?
	}

	private func _doTrain(
		request: TrainRequest,
		enginePool: EnginePool,
		logger: Logger,
		continuation: AsyncStream<ByteBuffer>.Continuation,
	) async throws {
		guard let modelContainer = await enginePool.getMLXModelAndTokenizer(modelId: request.model) else {
			_ = yieldSSE(
				TrainProgressChunk(
					type: "error", iteration: 0, trainingLoss: nil, validationLoss: nil,
					iterationsPerSec: nil, tokensPerSec: nil, checkpointPath: nil,
					message: "Model not found: \(request.model)",
					timestamp: Int64(Date().timeIntervalSince1970),
				), to: continuation,
			)
			return
		}

		var trainData: [String] = []
		var validData: [String] = []
		do {
			trainData = try _resolveDataset(input: request.trainingData, label: "train")
			if let valInput = request.validationData {
				validData = try _resolveDataset(input: valInput, label: "validation")
			} else {
				validData = Array(trainData.suffix(10))
			}
		} catch {
			_ = yieldSSE(
				TrainProgressChunk(
					type: "error", iteration: 0, trainingLoss: nil, validationLoss: nil,
					iterationsPerSec: nil, tokensPerSec: nil, checkpointPath: nil,
					message: "Dataset load failed: \(error.localizedDescription)",
					timestamp: Int64(Date().timeIntervalSince1970),
				), to: continuation,
			)
			return
		}
		guard !trainData.isEmpty else {
			_ = yieldSSE(
				TrainProgressChunk(
					type: "error", iteration: 0, trainingLoss: nil, validationLoss: nil,
					iterationsPerSec: nil, tokensPerSec: nil, checkpointPath: nil,
					message: "Training dataset is empty",
					timestamp: Int64(Date().timeIntervalSince1970),
				), to: continuation,
			)
			return
		}

		logger.info("Training started", metadata: [
			"model": .string(request.model),
			"trainSize": .string(String(trainData.count)),
			"lora_rank": .string(String(request.lora.rank)),
		])

		var trainResult: TrainResult?

		do {
			let snapshotTrain = trainData
			let snapshotValid = validData
			trainResult = try await modelContainer.perform { (ctx: MLXLMCommon.ModelContext) in
				guard ctx.model is (any LoRAModel) else {
					_ = yieldSSE(
						TrainProgressChunk(
							type: "error", iteration: 0, trainingLoss: nil, validationLoss: nil,
							iterationsPerSec: nil, tokensPerSec: nil, checkpointPath: nil,
							message: "Model does not support LoRA",
							timestamp: Int64(Date().timeIntervalSince1970),
						), to: continuation,
					)
					return TrainResult(success: false, iterations: 0, trainLoss: nil, validLoss: nil, adapterPath: nil, errMsg: "Model does not support LoRA")
				}

				_ = try LoRAContainer.from(model: ctx.model, configuration: LoRAConfiguration(
					numLayers: request.lora.numLayers,
					fineTuneType: .lora,
					loraParameters: LoRAConfiguration.LoRAParameters(
						rank: request.lora.rank,
						scale: request.lora.scale,
					),
				))

				let optimizer = Adam(learningRate: request.hyperparams.learningRate)

				var iterationsCompleted = 0
				var finalTrainLoss: Float?
				var finalValidLoss: Float?

				do {
					try LoRATrain.train(
						model: ctx.model,
						train: snapshotTrain,
						validate: snapshotValid,
						optimizer: optimizer,
						loss: LoRATrain.loss,
						tokenizer: ctx.tokenizer,
						parameters: LoRATrain.Parameters(
							batchSize: request.hyperparams.batchSize,
							iterations: request.hyperparams.iterations,
							stepsPerReport: request.hyperparams.stepsPerReport,
							stepsPerEval: request.hyperparams.stepsPerEval,
							validationBatches: request.hyperparams.validationBatches,
							saveEvery: request.hyperparams.saveEvery,
							adapterURL: nil,
						),
					) { progress in
						switch progress {
						case let .train(iter, tl, ips, tps):
							iterationsCompleted = iter + 1
							finalTrainLoss = tl
							_ = yieldSSE(
								TrainProgressChunk(
									type: "train", iteration: iter, trainingLoss: tl,
									validationLoss: nil, iterationsPerSec: ips, tokensPerSec: tps,
									checkpointPath: nil, message: progress.description,
									timestamp: Int64(Date().timeIntervalSince1970),
								), to: continuation,
							)
							return .more

						case let .validation(iter, vl, _):
							finalValidLoss = vl
							_ = yieldSSE(
								TrainProgressChunk(
									type: "validation", iteration: iter, trainingLoss: nil,
									validationLoss: vl, iterationsPerSec: nil, tokensPerSec: nil,
									checkpointPath: nil, message: progress.description,
									timestamp: Int64(Date().timeIntervalSince1970),
								), to: continuation,
							)
							return .more

						case let .save(iter, url):
							_ = yieldSSE(
								TrainProgressChunk(
									type: "save", iteration: iter, trainingLoss: nil,
									validationLoss: nil, iterationsPerSec: nil, tokensPerSec: nil,
									checkpointPath: url.path(), message: progress.description,
									timestamp: Int64(Date().timeIntervalSince1970),
								), to: continuation,
							)
							return .more
						}
					}

					guard let supportURL = FileManager.default.urls(
						for: .applicationSupportDirectory, in: .userDomainMask,
					).first else {
						throw NSError(domain: NSCocoaErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "applicationSupportDirectory unavailable"])
					}
					let adapterURL = supportURL.appendingPathComponent("ocoreai", isDirectory: true)
						.appendingPathComponent("adapters", isDirectory: true)
						.appendingPathComponent(
							"\(request.model)_lora_\(Int(Date().timeIntervalSince1970)).safetensors",
						)
					try FileManager.default.createDirectory(
						at: adapterURL.deletingLastPathComponent(),
						withIntermediateDirectories: true,
					)
					try LoRATrain.saveLoRAWeights(model: ctx.model, url: adapterURL)
					logger.info("Saved adapter: \(adapterURL.path())")

					return TrainResult(
						success: true,
						iterations: iterationsCompleted,
						trainLoss: finalTrainLoss,
						validLoss: finalValidLoss,
						adapterPath: adapterURL.path(),
						errMsg: nil,
					)
				} catch {
					logger.warning("Training error: \(error)")
					return TrainResult(
						success: false,
						iterations: iterationsCompleted,
						trainLoss: finalTrainLoss,
						validLoss: finalValidLoss,
						adapterPath: nil,
						errMsg: error.localizedDescription,
					)
				}
			}
		} catch {
			_ = yieldSSE(
				TrainProgressChunk(
					type: "error", iteration: 0, trainingLoss: nil, validationLoss: nil,
					iterationsPerSec: nil, tokensPerSec: nil, checkpointPath: nil,
					message: "Training setup failed: \(error.localizedDescription)",
					timestamp: Int64(Date().timeIntervalSince1970),
				), to: continuation,
			)
		}

		let final = trainResult ?? TrainResult(success: false, iterations: 0, trainLoss: nil, validLoss: nil, adapterPath: nil, errMsg: "Unknown error")
		_ = yieldSSE(
			TrainProgressChunk(
				type: "done",
				iteration: final.iterations,
				trainingLoss: final.trainLoss,
				validationLoss: final.validLoss,
				iterationsPerSec: nil, tokensPerSec: nil,
				checkpointPath: final.adapterPath,
				message: final.success
					? "Training completed: \(final.iterations) iterations"
					: "Training failed: \(final.errMsg ?? "unknown")",
				timestamp: Int64(Date().timeIntervalSince1970),
			), to: continuation,
		)
	}

	// MARK: - Evaluate Handler

	func evaluateHandler(
		request: EvalRequest,
		enginePool: EnginePool,
		logger: Logger,
	) async throws -> Response {
		guard !request.dataset.isEmpty else {
			throw AppError.invalidRequest("Evaluation dataset must not be empty")
		}

		logger.info("Evaluation started", metadata: [
			"model": .string(request.model),
			"datasetSize": .string(String(request.dataset.count)),
		])

		guard let modelContainer = await enginePool.getMLXModelAndTokenizer(modelId: request.model) else {
			throw AppError.invalidRequest("Model not found: \(request.model)")
		}

		let (loss, batches): (Float, Int) = await modelContainer.perform { ctx in
			let loss = LoRATrain.evaluate(
				model: ctx.model,
				dataset: request.dataset,
				loss: LoRATrain.loss,
				tokenizer: ctx.tokenizer,
				batchSize: request.batchSize,
				batchCount: request.maxBatches,
			)
			let batches = (request.dataset.count + request.batchSize - 1) / request.batchSize
			return (loss, batches)
		}

		let summary = EvalSummary(
			loss: loss,
			perplexity: loss,
			batchesEvaluated: batches,
			durationSeconds: 0,
		)

		var headers: HTTPFields = [:]
		headers[.contentType] = "application/json"
		let bodyData = try JSONEncoder().encode(summary)
		return Response(
			status: .ok,
			headers: headers,
			body: .init(contentsOf: [ByteBuffer(data: bodyData)]),
		)
	}

	// MARK: - Dataset Resolution

	private func _resolveDataset(input: TrainRequest.TrainingDatasetInput, label _: String) throws -> [String] {
		switch input {
		case let .inline(texts):
			return texts.filter { !$0.isEmpty }
		case let .file(path, _):
			guard FileManager.default.fileExists(atPath: path) else {
				throw AppError.invalidRequest("Dataset file not found: \(path)")
			}
			return try String(contentsOfFile: path, encoding: .utf8)
				.components(separatedBy: .newlines)
				.filter { !$0.isEmpty }
		}
	}

#endif
