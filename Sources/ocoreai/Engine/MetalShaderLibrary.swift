// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MetalShaderLibrary.swift — make MLX reach its shader library in a SwiftPM layout.
///
/// MLX loads its kernels from a `.metallib`, and `load_default_library`
/// (`mlx/backend/metal/device.cpp`) searches by PATH SHAPE:
///
/// | # | location |
/// |---|---|
/// | ⓪ | `MLX.GPU.metallib`, set before the first Metal call (checked before all others) |
/// | ① | `<executable dir>/mlx.metallib` |
/// | ② | `<executable dir>/Resources/mlx.metallib` |
/// | ③ | any *loaded* `NSBundle` named `mlx-swift_Cmlx` → `Contents/Resources/default.metallib` |
/// | ④ | `<executable dir>/Resources/default.metallib` |
///
/// ③ is why a bare `swift build` executable finds its shaders: SwiftPM leaves
/// `mlx-swift_Cmlx.bundle` next to the binary and `Bundle.main` resolves to that
/// directory. It is also why the *test* run does not: SwiftPM 6.4 puts the test
/// executable at `…/Debug/ocoreaiTests.xctest/Contents/MacOS/ocoreaiTests` while the
/// Cmlx bundle stays at `…/Debug/mlx-swift_Cmlx.bundle` — three levels up, with nothing
/// having loaded it. All five lookups miss, and the first Metal-touching suite aborts
/// the whole test process with `Failed to load the default metallib` (measured 10-14:
/// 352 tests in, no skip, no cause named — `make test-clt` died there for a day).
///
/// Copying the payload into the bundle is NOT an option: the build signs the bundle, and
/// a `.metallib` under `Contents/MacOS` counts as a nested code object, so the sign step
/// fails with `code object is not signed at all … mlx.metallib` (measured 10-14). Hence
/// ⓪: resolve the path in-process, once, before any inference.
///
/// `OCOREAI_METALLIB` names the payload explicitly (the test gate and a `serve` run from
/// a scratch tree use it). When nothing is found the override stays unset so MLX's own
/// search still runs, and the log says which file won — a kernel source the process
/// cannot name is the defect family this repo keeps tripping on.
///
/// The gates do not each guess where the payload is: `scripts/resolve-metallib.sh` is the one
/// ladder (env override → this scratch's SwiftPM product → an Xcode product → a pip wheel) and
/// it fails with the remedy when none is usable, because a run without a payload never reports.
///
/// ### Gate
/// `MetalShaderLibraryTests` pins the candidate order against a synthetic SwiftPM 6.4
/// layout — it goes red when the layout changes under us, which is what bit this host —
/// and the `$OCOREAI_METALLIB` precedence. `make test-clt` fails outright if there is no
/// payload to stage.
import Foundation
import Logging
import MLX

enum MetalShaderLibrary {
    /// Set this to an explicit `.metallib` path to bypass discovery.
    static let environmentVariable = "OCOREAI_METALLIB"

    /// Guards the once-only resolution. This is deliberately process-global: it must run
    /// before the first Metal call from a nonisolated init path, and MLX's override slot
    /// is itself a process global that cannot be actor-isolated. Mutations hold the lock.
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var didResolve = false

    /// Candidate payload paths for an executable, in search order: the explicit override
    /// first, then the executable's own directory, then its ancestors (the SwiftPM
    /// products directory sits above the `.xctest` bundle).
    ///
    /// Pure on purpose — the caller decides what exists, so the order is testable with no
    /// GPU and no filesystem writes.
    static func candidatePaths(
        executablePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> [String] {
        var ordered: [String] = []

        if let explicit = environment[environmentVariable], !explicit.isEmpty {
            ordered.append(explicit)
        }

        var dir = (executablePath as NSString).deletingLastPathComponent
        if dir.isEmpty { dir = FileManager.default.currentDirectoryPath }

        // Bounded walk: a scratch tree is never deeper than this, and an unbounded
        // loop to "/" would probe system directories on every engine start.
        for _ in 0 ..< 8 {
            ordered.append(contentsOf: [
                "\(dir)/mlx.metallib",
                "\(dir)/Resources/mlx.metallib",
                "\(dir)/Resources/default.metallib",
                "\(dir)/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib",
                "\(dir)/mlx-swift_Cmlx.bundle/Contents/Resources/mlx.metallib",
            ])
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return ordered
    }

    /// First candidate that exists and is non-empty.
    static func firstExisting(
        executablePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isUsable: (String) -> Bool = defaultUsabilityCheck,
    ) -> String? {
        for path in candidatePaths(executablePath: executablePath, environment: environment)
        where isUsable(path) {
            return path
        }
        return nil
    }

    /// Metal cannot load an empty archive, so a zero-byte file counts as absent.
    static func defaultUsabilityCheck(path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return false
        }
        return (attrs[.size] as? Int ?? 0) > 0
    }

    /// Resolve once per process. Safe (and intended) to call from every engine start.
    static func ensureResolved(logger: Logger) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if didResolve { return }
        didResolve = true

        // Respect anything already set (host app, tests, or an earlier caller).
        if let existing = MLX.GPU.metallib {
            logger.info("Metal shader library already set: \(existing.path)")
            return
        }

        let executable =
            CommandLine.arguments.first
            ?? Bundle.main.executablePath
            ?? "ocoreai"

        guard let chosen = firstExisting(executablePath: executable) else {
            // Leave the override unset: MLX's own search may still reach a payload (a
            // bundled .app ships one), and an empty override would hard-fail instead.
            let hint: String =
                "No Metal shader library found from \(executable) upward (checked mlx.metallib,"
                + " Resources/default.metallib, mlx-swift_Cmlx.bundle; $\(environmentVariable)"
                + " unset). Metal kernels will fail — stage a metallib or set $"
                + "\(environmentVariable)."
            // `Logger.Message` is string-interpolation-only (not String-assignable).
            logger.warning("\(hint)")
            return
        }

        MLX.GPU.metallib = URL(fileURLWithPath: chosen)
        logger.info("Metal shader library: \(chosen)")
    }
}
