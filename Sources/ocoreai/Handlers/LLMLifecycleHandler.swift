// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LLMLifecycleHandler.swift — LoRA fine-tuning + evaluation via MLX

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
    var success: Bool
    var iterations: Int
    var trainLoss: Float?
    var validLoss: Float?
    var adapterPath: String?
    var errMsg: String?
}

private func _doTrain(
    request: TrainRequest,
    enginePool: EnginePool,
    logger: Logger,
    continuation: AsyncStream<ByteBuffer>.Continuation,
) async throws {
    // Load-on-demand, the way a chat turn does. The old lookup only reported residency, so a
    // cold server refused the very id `/v1/models` advertises (measured 10-21); whatever this
    // throws already names the real reason — not found, still loading, or no MLX lane — and
    // that is what the stream says.
    let modelContainer: MLXLMCommon.ModelContainer
    do {
        modelContainer = try await enginePool.mlxContainer(modelId: request.model)
    } catch {
        _ = yieldSSE(
            TrainProgressChunk(
                type: "error", iteration: 0, trainingLoss: nil, validationLoss: nil,
                iterationsPerSec: nil, tokensPerSec: nil, checkpointPath: nil,
                message: "\(error)",
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

    logger.info(
        "Training started",
        metadata: [
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
                return TrainResult(
                    success: false, iterations: 0, trainLoss: nil, validLoss: nil, adapterPath: nil,
                    errMsg: "Model does not support LoRA")
            }

            // Capability before effort: upstream's LoRA loss runs `model as! any LLMModel`,
            // so a model that is not an LLMModel takes the whole process down (measured
            // 10-21 — this endpoint died mid-stream on a VLM checkpoint). Same predicate,
            // asked with `is`, answered with a refusal the client can act on.
            if let rejection = LoRAModelSupport.rejection(for: ctx.model) {
                _ = yieldSSE(
                    TrainProgressChunk(
                        type: "error", iteration: 0, trainingLoss: nil, validationLoss: nil,
                        iterationsPerSec: nil, tokensPerSec: nil, checkpointPath: nil,
                        message: rejection,
                        timestamp: Int64(Date().timeIntervalSince1970),
                    ), to: continuation,
                )
                return TrainResult(
                    success: false, iterations: 0, trainLoss: nil, validLoss: nil, adapterPath: nil,
                    errMsg: rejection)
            }

            // A 1-token sample has nothing to predict and traps inside mlx (LoRASampleDomain).
            // Counted with this model's own tokenizer — the one the batch iterator will use.
            let sampleTokenizer = ctx.tokenizer
            let sampleCounts: (String) -> Int = { sampleTokenizer.encode(text: $0).count }
            for dataset in [
                (rows: snapshotTrain, label: "trainingData"),
                (rows: snapshotValid, label: "validationData"),
            ] {
                guard
                    let violation = LoRASampleDomain.firstViolation(
                        dataset: dataset.rows, label: dataset.label, tokenCount: sampleCounts
                    )
                else { continue }
                let message = LoRASampleDomain.message(for: violation)
                _ = yieldSSE(
                    TrainProgressChunk(
                        type: "error", iteration: 0, trainingLoss: nil, validationLoss: nil,
                        iterationsPerSec: nil, tokensPerSec: nil, checkpointPath: nil,
                        message: message,
                        timestamp: Int64(Date().timeIntervalSince1970),
                    ), to: continuation,
                )
                return TrainResult(
                    success: false, iterations: 0, trainLoss: nil, validLoss: nil, adapterPath: nil,
                    errMsg: message)
            }

            _ = try LoRAContainer.from(
                model: ctx.model,
                configuration: LoRAConfiguration(
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
                    case .train(let iter, let tl, let ips, let tps):
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

                    case .validation(let iter, let vl, _):
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

                    case .save(let iter, let url):
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

                guard
                    let supportURL = FileManager.default.urls(
                        for: .applicationSupportDirectory, in: .userDomainMask,
                    ).first
                else {
                    throw NSError(
                        domain: NSCocoaErrorDomain, code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "applicationSupportDirectory unavailable"
                        ])
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

    let final =
        trainResult
        ?? TrainResult(
            success: false, iterations: 0, trainLoss: nil, validLoss: nil, adapterPath: nil,
            errMsg: "Unknown error")
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

    logger.info(
        "Evaluation started",
        metadata: [
            "model": .string(request.model),
            "datasetSize": .string(String(request.dataset.count)),
        ])

    // Same resolution as the train face and as chat: load on demand, then refuse honestly
    // with the reason actually hit.
    let modelContainer = try await enginePool.mlxContainer(modelId: request.model)

    let (loss, batches): (Float, Int) = try await modelContainer.perform { ctx in
        // The loss this call passes (`LoRATrain.loss`) casts `model as! any LLMModel`
        // upstream: without this guard the request traps the server instead of failing.
        if let rejection = LoRAModelSupport.rejection(for: ctx.model) {
            throw AppError.invalidParameter(
                param: "model", message: rejection, value: request.model)
        }

        // `LoRATrain.evaluate` has no pre-flight of its own upstream, so a 1-token sample
        // would reach the batch iterator and trap there.
        if let violation = LoRASampleDomain.firstViolation(
            dataset: request.dataset, label: "dataset",
            tokenCount: { ctx.tokenizer.encode(text: $0).count }
        ) {
            throw AppError.invalidParameter(
                param: "dataset[\(violation.index)]",
                message: LoRASampleDomain.message(for: violation),
                value: String(violation.tokenCount))
        }
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

private func _resolveDataset(input: TrainRequest.TrainingDatasetInput, label _: String) throws
    -> [String]
{
    switch input {
    case .inline(let texts):
        return texts.filter { !$0.isEmpty }
    case .file(let path, _):
        guard FileManager.default.fileExists(atPath: path) else {
            throw AppError.invalidRequest("Dataset file not found: \(path)")
        }
        return try String(contentsOfFile: path, encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
    }
}
