// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Testing

@testable import ocoreai

@Suite("DiscreteFlowScheduler (Wan 2.1 flow-matching Euler)")
struct Wan21SchedulerTests {
    @Test("sigma schedule 5-step, shift=3.0 matches diffusers FlowMatchEuler")
    func flowDiffusersParity5Step() {
        let scheduler = DiscreteFlowScheduler(
            stepCount: 5, trainStepCount: 1000, timeStepShift: 3.0)
        let expectedSigmas: [Float] = [1.0, 0.9003591, 0.7511211, 0.50298506, 0.00892857, 0.0]

        #expect(scheduler.sigmas.count == 6)
        for (i, (got, exp)) in zip(scheduler.sigmas, expectedSigmas).enumerated() {
            #expect(abs(got - exp) < 1e-4, "sigma[\(i)]: got \(got), expected \(exp)")
        }

        let expectedTimesteps: [Int] = [1000, 900, 751, 502, 8]
        for (i, (got, exp)) in zip(scheduler.timeSteps, expectedTimesteps).enumerated() {
            #expect(abs(got - exp) <= 1, "timestep[\(i)]: got \(got), expected \(exp)")
        }
    }

    @Test("sigma schedule 50-step (Wan default) endpoints correct")
    func flowDefault50Step() {
        let scheduler = DiscreteFlowScheduler(
            stepCount: 50, trainStepCount: 1000, timeStepShift: 3.0)

        #expect(scheduler.sigmas.count == 51)
        #expect(abs(scheduler.sigmas[0] - 1.0) < 1e-5)
        // Last meaningful sigma is ~0.009 (upstream `flowDiffusersParity50Step`)
        #expect(scheduler.sigmas[49] < 0.01)
        #expect(scheduler.sigmas[49] > 0.005)
        #expect(scheduler.sigmas[50] == 0.0)
    }

    @Test("sigma schedule 20-step endpoints match diffusers")
    func flow20Step() {
        let scheduler = DiscreteFlowScheduler(
            stepCount: 20, trainStepCount: 1000, timeStepShift: 3.0)

        #expect(scheduler.sigmas.count == 21)
        #expect(abs(scheduler.sigmas[0] - 1.0) < 1e-5)
        #expect(abs(scheduler.sigmas[1] - 0.9818746) < 1e-4)
        #expect(abs(scheduler.sigmas[19] - 0.00892857) < 1e-4)
        #expect(scheduler.sigmas[20] == 0.0)

        #expect(scheduler.timeSteps[0] == 1000)
        #expect(scheduler.timeSteps[19] <= 9)
    }

    @Test("Euler step matches diffusers formula (sample + output * dt)")
    func flowEulerStepParity() {
        let scheduler = DiscreteFlowScheduler(
            stepCount: 5, trainStepCount: 1000, timeStepShift: 3.0)
        let sample: [Float] = [1.0, 2.0, 3.0, 4.0]
        let output: [Float] = [0.5, -0.5, 1.0, -1.0]

        let result = scheduler.step(
            output: output, timeStep: scheduler.timeSteps[0], sample: sample)

        // dt = sigmas[1] - sigmas[0] = 0.9004 - 1.0 = -0.0996
        let dt = scheduler.sigmas[1] - scheduler.sigmas[0]
        let expected = zip(sample, output).map { $0 + $1 * dt }

        for (i, (got, exp)) in zip(result, expected).enumerated() {
            #expect(abs(got - exp) < 1e-6, "step result[\(i)]: got \(got), expected \(exp)")
        }
    }

    @Test("addNoise blends sample and noise at boundary and midpoint strengths")
    func addNoiseBehavior() {
        let scheduler = DiscreteFlowScheduler(stepCount: 20)
        let sample: [Float] = [1, 2, 3, 4]
        let noise: [Float] = [9, 8, 7, 6]

        // strength=0: original sample unchanged
        #expect(scheduler.addNoise(to: sample, noise: noise, at: 0.0) == sample)
        // strength=1: pure noise
        #expect(scheduler.addNoise(to: sample, noise: noise, at: 1.0) == noise)
        // strength=0.5: exact midpoint
        let mid = scheduler.addNoise(to: [0, 0], noise: [2, 4], at: 0.5)
        #expect(abs(mid[0] - 1.0) < 1e-6)
        #expect(abs(mid[1] - 2.0) < 1e-6)
    }

    @Test("sigmaMax constrains schedule start for img2img (and 1.0 == unbounded)")
    func sigmaMaxSchedule() {
        let strength: Float = 0.85
        let scheduler = DiscreteFlowScheduler(
            stepCount: 20, trainStepCount: 1000, timeStepShift: 1.0, sigmaMax: strength)
        #expect(scheduler.sigmas.first! <= strength + 1e-5)
        #expect(scheduler.startSigma == scheduler.sigmas.first!)

        // sigmaMax=1.0 matches the default (unconstrained) schedule
        let def = DiscreteFlowScheduler(stepCount: 20, trainStepCount: 1000, timeStepShift: 1.0)
        let withMax = DiscreteFlowScheduler(
            stepCount: 20, trainStepCount: 1000, timeStepShift: 1.0, sigmaMax: 1.0)
        #expect(def.sigmas == withMax.sigmas)
    }

    @Test("linspace produces evenly spaced values with correct count and near-exact endpoints")
    func linspaceEndpoints() {
        #expect(linspace(0.0, 1.0, 11).count == 11)
        let r11 = linspace(0.0, 1.0, 11)
        #expect(abs(r11.first! - 0.0) < 1e-6)
        #expect(abs(r11.last! - 1.0) < 1e-6)
        #expect(abs(r11[5] - 0.5) < 1e-5)

        #expect(linspace(0.0, 1.0, 1) == [0.0])
        #expect(linspace(0.0, 1.0, 0).isEmpty)

        // Evenly spaced (the real invariant): uniform step between consecutive
        // values, endpoints near-exact. Float32, so tolerances are ULP-scale.
        let r3 = linspace(-1.0, 3.0, 4)
        #expect(abs(r3.first! + 1.0) < 1e-6)
        #expect(abs(r3.last! - 3.0) < 1e-6)
        let step1 = r3[1] - r3[0]
        let step2 = r3[2] - r3[1]
        let step3 = r3[3] - r3[2]
        #expect(abs(step1 - 4.0 / 3.0) < 1e-5)
        #expect(abs(step1 - step2) < 1e-5)
        #expect(abs(step2 - step3) < 1e-5)
    }

    @Test(
        "step() applies the Euler update sample + output·(σ[i+1]−σ[i]); the chain telescopes to σ.last−σ[0]"
    )
    func stepEulerParity() {
        let scheduler = DiscreteFlowScheduler(
            stepCount: 4, trainStepCount: 1000, timeStepShift: 1.0)
        let sample: [Float] = [1, 2, 3, 4]
        let noise: [Float] = [1, 1, 1, 1]
        let sig = scheduler.sigmas  // [Float], length stepCount+1; via @testable

        // First Euler step uses Δσ = sig[1] − sig[0].
        let r1 = scheduler.step(output: noise, timeStep: 0, sample: sample)
        let d0 = sig[1] - sig[0]
        for i in 0 ..< 4 {
            #expect(abs(r1[i] - (Float(1 + i) + d0)) < 1e-4)
        }

        // Chain the remaining steps; total displacement telescopes to sig.last − sig[0].
        var cur = r1
        for _ in 1 ..< 4 { cur = scheduler.step(output: noise, timeStep: 0, sample: cur) }
        let totalDt = sig.last! - sig[0]
        for i in 0 ..< 4 {
            #expect(abs(cur[i] - (Float(1 + i) + totalDt)) < 1e-4)
        }
    }
}
