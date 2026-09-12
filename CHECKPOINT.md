# ocoreai checkpoint (09-12 18:0x, round 16)

## 状态
- 工作树: EngineInference.swift vs HEAD **0 diff**(两诊断探针全移除), 仅 untracked 本文件
- build: exit 0(8.07s, 无探针)
- 活体: 干净二进制红方块 -> "red"(9.4s) 无回归
- 进程: ps+lsof 双验 0, 8080 free

## VLM 视觉路结论(定性反转, 推翻第 14/15 轮假设)
- pipeline 已通: RPROBE3 实证 `Gemma4Processor` + prepare delta 252-258 (≈280 soft budget) + `lmInput.image=true`
- 模型行为面残存: 蓝方块 3/5 对 2/5 "无图"(小 VLM + 25 tool 面混淆 view_screen; 答过 blue => 读到了像素)
- 判据教训: 断点判定必须到 LMInput.image 层; prompt_tokens delta(A/B 3524) 被路径+工具面污染, 不可作判据
- 请求必须用全名 mlx-community/gemma-4-e2b-it-4bit(gemma-4-e2b 短名 => LLM 路由 404)

## 11 仓(全 behind=0)
- coreai +1 #245(iOS preset, macOS 0 消费) / vllm +16 / sglang +21(全 serving 面)
- codex +5(TUI, 非 Agent 语义层) / openclaw +270(TS 面) / hermes +88(无 agent-core 对位)

## 未决
- 2B VLM 视觉 QA 稳定性 = 模型能力面(需更大 VLM 或 prompt 层引导), 非 pipeline 缺口
- ANE-VLM 1221L 吸收 = 层 2 后续批(主视觉路已通)
