// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// BuiltInTools — registers essential tools into ToolRegistry on boot.
///
/// Each tool corresponds to a real capability (info, skill lookup, audit query).
///
/// Typed tools: use ``ToolEntry.typed(name:toolset:argsType:handler:)`` for
/// compile-safe argument decoding — mirrors Foundation Models ``Tool<Arguments, Output>``
/// pattern without requiring the framework.
import Foundation

/// Bootstrap the tool registry with built-in tools.
///
/// - Parameters:
///   - registry: The tool registry to populate.
///   - skillRegistry: Optional skill registry for skill-related tools.
func bootstrapBuiltInTools(
    registry: ToolRegistry,
    skillRegistry: SkillRegistry? = nil,
) async {
    // ── info ────────────────────────────────────────────────────────────────
    struct InfoArgs: Codable {
        let topic: String?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "info",
            toolset: "system",
            argsType: InfoArgs.self
        ) { args in
            switch args.topic ?? "status" {
            case "status": return "ocoreai runtime v0.7.0 — healthy"
            case "version": return "0.7.0"
            case "uptime": return "uptime: \(ProcessInfo.processInfo.systemUptime)"
            default: return "topic '\(args.topic ?? "unknown")' not recognized"
            }
        }
    )

    // ── skills_list ────────────────────────────────────────────────────────
    if let sr = skillRegistry {
        struct SkillsListArgs: Codable {
            let category: String?
        }

        try? await registry.register(
            ToolEntry.typed(
                name: "skills_list",
                toolset: "skills",
                argsType: SkillsListArgs.self
            ) { [sr] args in
                let names: [String] =
                    if let cat = args.category, !cat.isEmpty {
                        await sr.lookupCategory(cat).map(\.name)
                    } else {
                        await sr.list()
                    }
                if names.isEmpty {
                    return "no skills found"
                }
                return names.joined(separator: ", ")
            }
        )
    }

    // ── skills_lookup ──────────────────────────────────────────────────────
    if let sr = skillRegistry {
        struct SkillsLookupArgs: Codable {
            let name: String
        }

        try? await registry.register(
            ToolEntry.typed(
                name: "skills_lookup",
                toolset: "skills",
                argsType: SkillsLookupArgs.self
            ) { [sr] args in
                guard !args.name.isEmpty else { return "error: name required" }
                guard let skill = await sr.lookup(args.name) else {
                    return "skill '\(args.name)' not found"
                }
                return "\(skill.name)\n\(skill.description)\nCategory: \(skill.category)"
            }
        )
    }

    // ── skills_view ────────────────────────────────────────────────────────
    if let sr = skillRegistry {
        struct SkillsViewArgs: Codable {
            let name: String
            let file: String?
        }

        try? await registry.register(
            ToolEntry.typed(
                name: "skills_view",
                toolset: "skills",
                argsType: SkillsViewArgs.self
            ) { [sr] args in
                guard !args.name.isEmpty else { return "error: name required" }
                if let file = args.file {
                    // Delegated to skill system — return path for later resolve
                    return "resolve: \(args.name)/\(file)"
                }
                guard let skill = await sr.lookup(args.name) else {
                    return "skill '\(args.name)' not found"
                }
                return skill.promptContent
            }
        )
    }

    // ── read_file ───────────────────────────────────────────────────────────
    struct ReadFileArgs: Codable {
        let path: String
        let offset: Int?
        let limit: Int?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "read_file",
            toolset: "files",
            argsType: ReadFileArgs.self,
            schema: ToolSchema(parameters: [
                "path": ToolParameter(
                    type: .string, description: "File path (absolute, ~, or cwd-relative)"),
                "offset": ToolParameter(
                    type: .integer, description: "1-based first line to read (default 1)"),
                "limit": ToolParameter(
                    type: .integer, description: "Max lines to read (default 2000)"),
            ])
        ) { args in
            try FileTools.read(path: args.path, offset: args.offset, limit: args.limit)
        }
    )

    // ── write_file ──────────────────────────────────────────────────────────
    struct WriteFileArgs: Codable {
        let path: String
        let content: String
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "write_file",
            toolset: "files",
            argsType: WriteFileArgs.self,
            description: "Write (create or replace) a text file; verified by read-back",
            schema: ToolSchema(parameters: [
                "path": ToolParameter(
                    type: .string, description: "File path to create or overwrite"),
                "content": ToolParameter(type: .string, description: "Full new content"),
            ]),
            isDestructive: true
        ) { args in
            try FileTools.write(path: args.path, content: args.content)
        }
    )

    // ── edit_file ───────────────────────────────────────────────────────────
    struct EditFileArgs: Codable {
        let path: String
        let oldString: String
        let newString: String
        let occurrences: Int?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "edit_file",
            toolset: "files",
            argsType: EditFileArgs.self,
            description:
                "Search-and-replace in one file; requires exact match count, verifies by read-back",
            schema: ToolSchema(parameters: [
                "path": ToolParameter(type: .string, description: "File path to edit"),
                "oldString": ToolParameter(
                    type: .string,
                    description: "Exact text to find (must occur exactly `occurrences` times)"),
                "newString": ToolParameter(
                    type: .string, description: "Replacement text (empty = delete)"),
                "occurrences": ToolParameter(
                    type: .integer, description: "Expected match count (default 1)"),
            ]),
            isDestructive: true
        ) { args in
            try FileTools.editFile(
                path: args.path,
                oldString: args.oldString,
                newString: args.newString,
                occurrences: args.occurrences
            )
        }
    )

    // ── search_files ────────────────────────────────────────────────────────
    struct SearchFilesArgs: Codable {
        let path: String
        let pattern: String
        let target: String?
        let limit: Int?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "search_files",
            toolset: "files",
            argsType: SearchFilesArgs.self,
            schema: ToolSchema(parameters: [
                "path": ToolParameter(
                    type: .string, description: "Directory (or file) to search in"),
                "pattern": ToolParameter(
                    type: .string,
                    description:
                        "Filename glob (* supported) in files mode, substring in content mode"),
                "target": ToolParameter(type: .string, description: "files (default) or content"),
                "limit": ToolParameter(type: .integer, description: "Max results (default 50)"),
            ])
        ) { args in
            try FileTools.search(
                path: args.path, pattern: args.pattern, target: args.target, limit: args.limit)
        }
    )

    // ── exec_command ────────────────────────────────────────────────────────
    // Baseline: codex unified exec — `ToolName::plain("exec_command")`
    // (`core/src/unified_exec/process_manager.rs:1308`), zsh (`core/src/shell.rs`),
    // `ExecApprovalRequest` gating before execution (approval = user-side).
    struct ExecCommandArgs: Codable {
        let command: String
        let cwd: String?
        let timeoutSeconds: Int?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "exec_command",
            toolset: "shell",
            argsType: ExecCommandArgs.self,
            description:
                "Run a shell command via /bin/zsh -c and return stdout, stderr, and exit code",
            schema: ToolSchema(parameters: [
                "command": ToolParameter(
                    type: .string, description: "Shell command line to execute under zsh"),
                "cwd": ToolParameter(
                    type: .string,
                    description: "Optional working directory (absolute, `~`-expanded, or relative)"),
                "timeoutSeconds": ToolParameter(
                    type: .integer,
                    description: "Optional timeout in seconds (clamped to 1–300, default 60)"),
            ]),
            isDestructive: true
        ) { args in
            try await ExecTools.run(
                command: args.command,
                cwd: args.cwd,
                timeoutSeconds: args.timeoutSeconds ?? ExecTools.defaultTimeoutSeconds
            )
        }
    )

    // ── exec_shell / write_stdin / exec_poll — session exec surface ────────
    // Baseline: codex `unified_exec` (references/codex, HEAD):
    //   - `exec_command` yield form (`tools/handlers/unified_exec/exec_command.rs`,
    //     `core/src/unified_exec/mod.rs` `clamp_yield_time` 250–30_000ms
    //     default 10_000) → ocoreai `exec_shell`: spawn, yield ≤ yieldMs,
    //     return a session the model keeps polling.
    //   - `write_stdin` (`tools/handlers/unified_exec/write_stdin.rs`,
    //     `process_manager.rs:824-832` dual regime): non-empty write clamps
    //     to 250–30_000 (default 250); **empty poll clamps to 5_000–300_000
    //     (default 5_000**, `DEFAULT_MAX_BACKGROUND_TERMINAL_TIMEOUT_MS`) →
    //     ocoreai `write_stdin` mirrors both forms + both clamp branches.
    //   - `exec_poll`: poll-only alias of the same drain (empty regime).
    // Additive to `exec_command` (pinned blocking contract, 9-test gate in
    // `ExecCommandToolTests.swift`): `exec_command` stays for short
    // block-and-report; the session trio serves long-running / interactive
    // children (dev servers, REPLs, watch builds).
    struct ExecShellArgs: Codable {
        let command: String
        let cwd: String?
        let yieldMs: Int?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "exec_shell",
            toolset: "shell",
            argsType: ExecShellArgs.self,
            description:
                "Start a long-running / interactive shell session via /bin/zsh -c. "
                + "Returns a session id plus the output produced during the yield "
                + "window (clamped to 250–30000 ms, default 10000). Keep the id, "
                + "then drive the child with `write_stdin` (send stdin, optionally "
                + "yield) or `exec_poll` (yield without writing). For one-shot "
                + "commands, prefer `exec_command`.",
            schema: ToolSchema(parameters: [
                "command": ToolParameter(
                    type: .string, description: "Shell command line to run under zsh"),
                "cwd": ToolParameter(
                    type: .string,
                    description: "Optional working directory (absolute, `~`-expanded)"),
                "yieldMs": ToolParameter(
                    type: .integer,
                    description: "How long to wait for output before returning "
                        + "(ms; clamped to 250–30000, default 10000)"),
            ]),
            isDestructive: true
        ) { args in
            let res = try await ExecSessionManager.shared.spawn(
                command: args.command,
                cwd: args.cwd,
                yieldMs: args.yieldMs ?? ExecSessionManager.defaultYieldMs
            )
            let status =
                res.completed
                ? "finished"
                : "alive — send stdin with `write_stdin`, collect more output with `exec_poll`"
            return "\(res.report)\nsession_id: \(res.sessionId) (\(status))"
        }
    )

    struct WriteStdinArgs: Codable {
        let sessionId: Int
        let data: String?
        let yieldMs: Int?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "write_stdin",
            toolset: "shell",
            argsType: WriteStdinArgs.self,
            description:
                "Write text to a shell session's stdin (no implicit newline), then "
                + "yield up to `yieldMs` and return the new output. With empty "
                + "`data` this is a pure poll (the stdin pipe is never touched).",
            schema: ToolSchema(parameters: [
                "sessionId": ToolParameter(
                    type: .integer, description: "Session id returned by `exec_shell`"),
                "data": ToolParameter(
                    type: .string,
                    description: "Text to write to the child's stdin "
                        + "(default empty = poll only)"),
                "yieldMs": ToolParameter(
                    type: .integer,
                    description: "How long to wait for output after the write "
                        + "(ms; non-empty write clamped 250–30000, default 250)"),
            ]),
            isDestructive: true
        ) { args in
            let res = try await ExecSessionManager.shared.writeStdin(
                sessionId: args.sessionId,
                data: args.data ?? "",
                yieldMs: args.yieldMs
            )
            let status =
                res.completed
                ? "finished"
                : "alive — more input: `write_stdin`, more output: `exec_poll`"
            return "\(res.report)\nsession_id: \(args.sessionId) (\(status))"
        }
    )

    struct ExecPollArgs: Codable {
        let sessionId: Int
        let yieldMs: Int?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "exec_poll",
            toolset: "shell",
            argsType: ExecPollArgs.self,
            description:
                "Yield up to `yieldMs` on a shell session and return the new output "
                + "(no stdin write). A finished session returns its final report.",
            schema: ToolSchema(parameters: [
                "sessionId": ToolParameter(
                    type: .integer, description: "Session id returned by `exec_shell`"),
                "yieldMs": ToolParameter(
                    type: .integer,
                    description: "How long to wait for output "
                        + "(ms; empty poll clamped 5000–300000, default 5000)"),
            ]),
            isDestructive: true
        ) { args in
            let res = try await ExecSessionManager.shared.poll(
                sessionId: args.sessionId,
                yieldMs: args.yieldMs
            )
            let status =
                res.completed
                ? "finished"
                : "alive — send input with `write_stdin`"
            return "\(res.report)\nsession_id: \(args.sessionId) (\(status))"
        }
    )

    // ── view_image ──────────────────────────────────────────────────────────
    // Baseline: codex `view_image` (`core/src/tools/handlers/view_image_spec.rs`,
    // `VIEW_IMAGE_TOOL_NAME` = "view_image") — "View a local image file from the
    // filesystem when visual inspection is needed." One required `path`;
    // optional `detail` ("high" | "original"). ocoreai's pre-flight half:
    // verify the file is a real decodable image + report true WxH (ImageIO).
    struct ViewImageArgs: Codable {
        let path: String
        let detail: String?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "view_image",
            toolset: "files",
            argsType: ViewImageArgs.self,
            description:
                "Verify an on-disk image file is a real decodable image and report "
                + "its path, extension, MIME, byte size, and true pixel dimensions",
            schema: ToolSchema(parameters: [
                "path": ToolParameter(
                    type: .string,
                    description: "Filesystem path to an image file (absolute, `~`, or relative)"),
                "detail": ToolParameter(
                    type: .string,
                    description:
                        "Detail level: `high` (default) or `original` (echo of the "
                        + "codex spec vocabulary; ocoreai does not resize)"),
            ])
        ) { args in
            let report = try ViewImage.run(path: args.path, detail: args.detail)
            return ViewImage.reportString(report)
        }
    )

    // ── echo ────────────────────────────────────────────────────────────────
    struct EchoArgs: Codable {
        let message: String?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "echo",
            toolset: "debug",
            argsType: EchoArgs.self
        ) { args in
            args.message ?? ""
        }
    )

    // ── get_context_remaining ────────────────────────────────────────────────
    // codex `get_context_remaining`(06d2c64, 逐行对齐): 无参, 报告当前上下文窗口剩余 token。
    //   真值 = turn 入口(ChatHandler)每轮已算的 promptTokenCount(used) + 模型窗口(limit)
    //   → 写进 ContextStatusStore;本工具读时算 `max(0, limit - used)`,无窗口/无活跃会话→unknown。
    //   基准: codex core/src/session/context_window.rs(tokens_remaining) +
    //        core/src/context/token_budget_context.rs:170-172(report 逐字)。
    let contextStore = ContextStatusStore.shared
    try? await registry.register(GetContextRemainingClient.toolEntry(store: contextStore))
    // 获取信息一等工具。基准: codex ToolSpec::WebSearch (tool_spec.rs:39)。
    // 本地推理无 provider 代搜 → handler 调 ollama /v1/responses web_search。
    try? await registry.register(WebSearchClient.toolEntry())

    // ── web_fetch ──────────────────────────────────────────────────────────
    // 读取已知 URL 的渲染内容(WebKit 后端)。与 web_search 正交:
    //   web_search=找答案, web_fetch=读具体页面(JS 渲染站纯 HTTP 拿不到,WebKit 能)。
    try? await registry.register(WebFetchClient.toolEntry())

    // ── view_screen ────────────────────────────────────────────────────────
    // 视觉感知轴的 agent 可触面: 截当前屏幕 + Vision OCR 出屏幕文字(文本通道,
    // 不吐像素)。基础设施复用已验证的 ScreenshotService(ScreenCaptureKit) +
    // VisionOCR —— PerceptionEngine 已在 UI 侧消费同一管线;本工具补 agent 面。
    try? await registry.register(ScreenCaptureClient.toolEntry())

    // ── transcribe_audio ───────────────────────────────────────────────────
    // 听觉感知轴的 agent 可触面: 复用已建的音频基设(而非另造)——
    //   LocalSTT(L3, macOS 26 / iOS 26+ 离线 Speech framework 文件识别)
    //   + AudioIO 的 live-mic 兜底阶梯。返回识别文字(文本通道,非音频)。
    // 基设已在 UI press-to-talk / MultimodalHandler(HTTP /v1/multimodal)侧消费;
    // 本工具补 agent 面 —— 与 view_screen 同一「基设已建、补 agent 面」形态。
    try? await registry.register(TranscribeAudioClient.toolEntry())

    // ── speak ──────────────────────────────────────────────────────────────
    // 语音反馈轴的 agent 可触面: 复用 AudioIO.speak + PersonalVoiceTTS(L1,
    // 用户自己的声音, floor=部署 floor 14/17 → 八版全 eligible)。
    // MultimodalSpeakHandler(HTTP)已用同一 seam;本工具把它接到模型可调度面。
    try? await registry.register(SpeakClient.toolEntry())

    // ── generate_video ─────────────────────────────────────────────────────
    // 视频生成轴(五要素④)的 agent 可触面: 复用已 absorb 的视频基设
    //   WanPipeline(coreai-models conformer, 27 门控面)→ [CGImage]
    //   + VideoWriter(coreai-models Output, 纯 AVFoundation)→ mp4/gif/apng/webp。
    // 低于 floor / 无 CoreAI / 权重未部署 → 诚实上报, 不静默失败。
    try? await registry.register(GenerateVideoClient.toolEntry())

    // ── clock ──────────────────────────────────────────────────────────────
    // codex `clock` namespace 两个 agent-loop 原语(0.150.1 HEAD): 读时间 + 受控等待。
    //   curr_time  无参, UTC `YYYY-MM-DD HH:MM:SS UTC`(codex current_time.rs)
    //   sleep      `duration_ms` 1..43,200,000(12h) 报墙钟经过秒(codex sleep.rs)
    // ocoreai 此前 0 注册(agent 想读时间只能靠 info.uptime 间接推;想等只能靠
    // exec sleep 走子进程)→ 本批补一等原语。命名/取值/报告形态逐行对齐 codex。
    try? await registry.register(CurrTimeClient.toolEntry())
    try? await registry.register(SleepClient.toolEntry())
}
