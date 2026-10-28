// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// The delivery form has to be judged on the artifact, not on the SDK sitting on disk.
///
/// `scripts/toolchain-contract.sh` checks R1 (no CoreAI in the delivery SDK) against routes —
/// correctly, and by compiling a kernel for Metal. But `make release` was a bare
/// `swift build -c release`, so whichever SDK the host happened to carry decided the shape of
/// what ships: measured on this host, the produced binary weak-links
/// `CoreAI.framework`, i.e. the macOS-27 form, while the CI release leg on an SDK-26 image
/// builds the other one under the same name. A HARD rule about the shipping shape that no check
/// applies to the shipping artifact is a claim, not a gate.
///
/// These scans floor their own premises so a regex that stopped matching fails the run.

import Foundation
import Testing

@testable import ocoreai

private func formRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/",
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    {
        root.deleteLastPathComponent()
    }
    #expect(root.path != "/", "repo root not found from \(#filePath)")
    return root
}

private func read(_ relative: String) throws -> String {
    try String(contentsOf: formRoot().appendingPathComponent(relative), encoding: .utf8)
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

@Suite("Release artifacts — the shipping shape is asserted, not assumed")
struct ReleaseArtifactFormTests {

    /// The judge exists, and is runnable by name from the Makefile and the bundling script.
    @Test func artifactCheckerExists() {
        let url = formRoot().appendingPathComponent("scripts/release-artifact-check.sh")
        let exists = FileManager.default.fileExists(atPath: url.path)
        #expect(exists, "scripts/release-artifact-check.sh must exist")
        let perms =
            try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber
        let executable = (perms?.uint16Value ?? 0) & 0o111 != 0
        #expect(executable, "the checker must be executable, got \(String(describing: perms))")
    }

    /// The two release targets are not interchangeable, and each states which shape it demands.
    @Test func releaseTargetsNameTheirForm() throws {
        let makefile = try read("Makefile")
        let delivery = occurrences(
            of: "release-artifact-check.sh delivery", in: makefile)
        #expect(delivery == 1, "`release` asserts delivery once, saw \(delivery)")
        let mac27 = occurrences(
            of: "release-artifact-check.sh macos27", in: makefile)
        #expect(mac27 == 1, "`release-mac27` asserts its form once, saw \(mac27)")
        let total = occurrences(of: "release-artifact-check.sh", in: makefile)
        #expect(total == 2, "no release path escapes the judgement, saw \(total)")
        let phony = occurrences(of: "release-mac27", in: makefile)
        #expect(phony >= 2, "declared in .PHONY and defined, saw \(phony)")
        // The two forms must not share a product path: `.build/release` is what the probes and
        // the scoreboard read, so a macOS-27 binary left there is the delivery trap again.
        let ownScratch = occurrences(of: "--scratch-path .build-mac27", in: makefile)
        #expect(ownScratch == 1, "macos27 builds in its own scratch, saw \(ownScratch)")
        let mac27Path = occurrences(of: "macos27 .build-mac27/release/ocoreai", in: makefile)
        #expect(mac27Path == 1, "macos27 judges its own path, saw \(mac27Path)")
        let deliveryPath = occurrences(of: "delivery .build/release/ocoreai", in: makefile)
        #expect(deliveryPath == 1, "delivery judges .build/release, saw \(deliveryPath)")
    }

    /// The delivery route is pinned, never inherited — because the host here is exactly the case
    /// that breaks it (Xcode SDK 27 carries CoreAI.framework). Pinned by the ladder that owns the
    /// decision, not by a copy of it in the recipe: `release` evals `print-delivery-env`, and the
    /// same resolver is what `build-app.sh` uses for the .app a user installs. This test is where
    /// that rule was broken once — it grepped for `DEVELOPER_DIR=$(CLT_DIR)`/`$(SDKROOT_CLT)` and
    /// went red the day the literals moved into the resolver, which is the second-home AGENTS.md
    /// forbids. It now asserts the ladder itself, so a route that stops being pinned still goes
    /// red, and so does a pin that drifts out of the resolver.
    @Test func deliveryTargetPinsTheRouteInsteadOfInheritingIt() throws {
        let makefile = try read("Makefile")
        let start = makefile.range(of: "\nrelease:\n")
        #expect(start != nil, "a `release:` target must exist")
        let body =
            String(makefile[(start!.upperBound)...]).components(
                separatedBy: "\n\n"
            ).first ?? ""
        #expect(
            body.contains("toolchain-contract.sh") && body.contains("print-delivery-env"),
            "delivery must take its route from the resolver that owns it, not the ambient host: \(body)"
        )
        #expect(
            body.contains("$$OCOREAI_DELIVERY_FLAGS"),
            "delivery must pass the resolver's framework/rpath flags, not its own copy: \(body)")
        let judges = body.contains("release-artifact-check.sh delivery")
        #expect(judges, "delivery judges its own artifact: \(body)")
        // The pin lives in the resolver: the CLT developer dir, an SDK chosen by name, and no
        // delivery build at all when no CoreAI-free SDK exists (inheriting Xcode's is the defect).
        let resolver = try read("scripts/toolchain-contract.sh")
        #expect(
            resolver.contains("export DEVELOPER_DIR=$CLT_ROOT"),
            "the resolver no longer pins the CLT route — delivery would inherit the host")
        #expect(
            resolver.contains("export SDKROOT=$DELIVERY_SDK"),
            "the resolver no longer pins an explicit SDK, never the MacOSX.sdk symlink")
        #expect(
            resolver.contains("no CoreAI-free MacOSX SDK"),
            "a host without a CoreAI-free SDK must fail the delivery build, not fall back")
        // One ladder, two consumers: the installer path reads the same resolver.
        let bundling = try read("scripts/build-app.sh")
        #expect(
            bundling.contains("print-delivery-env"),
            "the .app a user installs drifted off the delivery ladder")
    }

    /// The bundling path — the bundle a user installs — is judged too, not just the binary.
    @Test func bundlingScriptJudgesItsBinary() throws {
        let script = try read("scripts/build-app.sh")
        let judges = occurrences(of: "release-artifact-check.sh\" delivery", in: script)
        #expect(judges == 1, "build-app.sh asserts delivery once, saw \(judges)")
        let strict = script.contains("set -euo pipefail")
        #expect(strict, "a failed judgement must abort the bundle")
    }

    /// The checker itself must not pass vacuously: it needs load commands to judge, greps the
    /// framework by name, and has distinct exits for usage (2) and mismatch (1).
    @Test func checkerFloorsItsOwnPremises() throws {
        let script = try read("scripts/release-artifact-check.sh")
        let frameworkFloor = occurrences(of: "\\.framework/", in: script)
        #expect(frameworkFloor >= 1, "it refuses a binary with no frameworks: \(frameworkFloor)")
        let coreaiGrep = occurrences(of: "CoreAI", in: script)
        #expect(coreaiGrep >= 3, "CoreAI named by the scan and both remedies, saw \(coreaiGrep)")
        let minosCheck = occurrences(of: "minos", in: script)
        #expect(minosCheck >= 3, "the declared floor is read and reported, saw \(minosCheck)")
        let usageExit = occurrences(of: "exit 2", in: script)
        #expect(usageExit >= 2, "bad form/args exit 2, saw \(usageExit)")
        let failExit = occurrences(of: "exit 1", in: script)
        #expect(failExit >= 4, "missing/unjudgeable/mismatch exit 1, saw \(failExit)")
    }
}
