---
name: claude-cli
description: 用 claude CLI(外部 Claude 实例,非交互 -p 模式)起独立任务 session,**优先用于方案/分析/审视型任务**。
  支持多 session 并行、按 name 续聊、本地存档(sid/desc/last/full)。
  触发词:"用 claude 出方案/分析/审视/评估"、"让外部 claude 看一眼方案"、"起一个 claude 做思路梳理"、
  "并行起多个 claude 评估 X/Y 方案"、"接着上次 claude 那个 X 继续"。
  当用户想"启动外部 claude 实例做分析、出方案、审视思路"时使用。
  实现/写代码型任务优先用 `codex-cli` skill。
  注意:本对话里的"你"就是 Claude Code,用户说"你帮我分析"通常不是触发本 skill;
  只有明确表达"起一个外部的、独立的 claude"或"在后台让 claude"才用。
---

# claude-cli skill

用 claude CLI(`claude -p ...`)起非交互 session、跨调用续聊、多 session 并行。底层走用户自定义 shell 函数 `ai-claude*`,默认走 `~/.claude/settings.json`(Opus 4.7 1M + xhigh + bypassPermissions)。

## 使用场景定位

**claude 是"方案型 agent"——优先派给它做思考/审视/出方案**:

| 适合 claude 的任务 | 不适合 claude(改派 codex-cli) |
|---|---|
| 出技术方案、做架构选型 | 实现一个新函数/模块 |
| 评估几种方案的取舍 | 重构现有代码 |
| 审 PRD/需求文档 | 加单元测试 |
| 写技术分析、思路梳理 | 修 bug、补类型 |
| 分析现状(只读不动手) | 改文件结构、批量编辑 |
| 给一段代码出几种重构思路 | 加 CLI flag |

简记:**claude 出方案,codex 干活**。任务里有"分析/方案/思路/审视/评估" → 用 claude;有"实现/写/改/重构/加测试" → 用 codex。

如果用户给的任务**既要出方案又要落地**:先用 claude 出方案,人审过后,再让 codex 按方案实现。

## 开工扫描(建议)

如果对话上下文里**不清楚现有 session 状态**——比如用户提到某个 name 但你不确定它是否存在,或跨会话恢复完全没有上文——先跑一次:

```bash
ai-sessions
```

如果对话里已经很清楚(刚起的 session、用户明说"新起 X"),**跳过这步直接干**。

## 核心命令

| 场景 | 命令 |
|---|---|
| 新起 session | `ai-claude <name> "<desc>" "<prompt>"` |
| 续聊 session | `ai-claude-c <name> "<prompt>"` |
| 列出所有 session | `ai-sessions` |
| 删除某 session | `ai-rm <name>`(短名歧义时用完整 `claude-<name>`) |

## name + desc 规则

- **name**:kebab-case,短(2-4 词),语义化。例:`plan-auth-redesign`、`eval-cache-options`、`audit-pr-123`
- **desc**:**必填**,≥ 15 字符,讲清"这个 session 在做什么"
  - 好例:"评估 Redis vs Memcached 在缓存层的取舍"、"梳理登录改造的方案与影响范围"
  - 反例:"看看"、"想一下"

## 提示词五件套(每条 prompt 都应覆盖)

外部 claude **没看过本对话**,prompt 必须自包含:

- **[目标]** 动词开头,要它做什么(如"评估"、"梳理"、"对比"、"分析")
- **[背景]** agent 从 cwd 看不出的事(项目阶段、隐性约束、决策由来)
- **[输入]** 让它读哪些文件、跑什么命令(给具体路径,不让猜)
- **[约束]** 不能改什么(方案类默认 **"只分析,不改任何文件"**)、输出语言
- **[产出]** 形式(方案对比表/清单/利弊分析)+ 长度(如 "500 字内")

## 安全约束(自动追加)

shell 函数自动在每条 prompt 末尾追加:

> 约束:不要执行 git commit 或 git push。

⚠️ claude 默认 `bypassPermissions` 模式——**会改文件**。方案/分析类任务务必在 prompt 里显式写"约束:只分析,不要修改任何文件"。

## 改文件场景:也要 worktree

claude 的主要场景是**只读分析**,但如果一定要让它动手改文件(例:"按你的方案直接实现"),那就跟 codex-cli 一样**走 worktree 隔离**——完整流程见 `codex-cli` skill 的"开发工作流"段,只是把 `ai-codex` 换成 `ai-claude`。

## 反模式 vs 正模式

❌ 不假设跨 session 共享上下文:
```bash
ai-claude plan-a "评估方案 A: ..."
ai-claude plan-b "评估方案 B,跟 A 对比"        # B 不知道 A 是啥
```

✅ 各 session prompt 自包含:
```bash
ai-claude plan-a "<desc>" "[目标] 评估方案 A: <完整描述>"
ai-claude plan-b "<desc>" "[目标] 评估方案 B: <完整描述>。与 A 的差异:<列出来>"
# 之后 Claude Code 自己拿两个结果做对比,不让 B 知道 A
```

---

❌ 续聊时用模糊指代:
```bash
ai-claude-c x "继续刚才那个"
```

✅ 续聊写新增信息 + 具体指令:
```bash
ai-claude-c x "你方案 A 里说要用 Redis Pub/Sub,但我们的运维不支持 Pub/Sub。换个等价方案。"
```

---

❌ 让 claude 改文件不带 worktree:
```bash
cd ~/project/foo                  # 还在 feat/auth 分支
ai-claude add-types "<desc>" "给 utils.ts 加类型注解,要改文件"   # 直接污染 feat/auth
```

✅ 改文件也走 worktree:
```bash
cd ~/project/foo
git worktree add ../foo-claude-add-types -b claude-add-types
cd ../foo-claude-add-types
ai-claude add-types "<desc>" "<prompt>"
# 完整流程见 codex-cli skill 的"开发工作流"
```

## 并行评估方案的典型场景

让 claude 并行评估 3 个方案,然后 Claude Code 自己汇总对比:

```bash
ai-claude plan-a "评估方案 A" "[目标] 评估方案 A: <完整描述>。[约束] 只分析。[产出] 优劣表,300 字内。" &
ai-claude plan-b "评估方案 B" "[目标] 评估方案 B: <完整描述>。[约束] 只分析。[产出] 优劣表,300 字内。" &
ai-claude plan-c "评估方案 C" "[目标] 评估方案 C: <完整描述>。[约束] 只分析。[产出] 优劣表,300 字内。" &
wait

# 然后 Claude Code 自己读 3 个 last.txt,做整合对比给用户
cat .ai-sessions/claude-plan-{a,b,c}/last.txt
```

并行上限同 codex-cli:N ≤ 5 直接跑,N > 5 警告"任务多,建议拆批"。

## 续聊规则

续聊时 claude **已经记着第一轮所有上下文**:
- **不要重复背景**
- 只写**新增信息 + 新指令**

## 常见错误 → 修复

| 错误 | 修复 |
|---|---|
| `❌ session 'claude-x' 已存在` | 续聊 `ai-claude-c x "..."` / 重置 `ai-rm claude-x && ai-claude x "..." "..."` |
| `❌ session 'claude-x' 不存在` | 用 `ai-claude x "<desc>" "..."` 新起 |
| `❌ desc 至少 15 字符` | desc 写长 |
| `❌ name 必须是 kebab-case` | 小写字母+数字+连字符 |
| `command not found: ai-claude` | `source ~/.config/zsh/ai-cli.zsh` |
| claude 卡很久不返回 | Opus 4.7 1M + xhigh,长任务 1-5 分钟正常 |
| 输出疑似不完整 | `-p` 默认 text format 只输出 final message;看过程读 `full.log` |

## 文件结构

**所有 session 集中在主项目根的 `.ai-sessions/`**——无论在主项目还是 worktree 里跑,session 元数据都落主项目(通过 `git rev-parse --git-common-dir` 定位)。

```
<主项目根>/.ai-sessions/claude-<name>/
  sid          # session UUID(预生成)
  desc         # 描述
  last.txt     # 最新一轮的 final message
  full.log     # 完整对话累加
```

worktree 删除不影响 session;`ai-sessions` 在任意位置都看到完整列表。

## 进阶:覆盖默认模型/思考(默认不传)

**默认绝对不传** model/effort,走 `~/.claude/settings.json`(Opus 4.7 1M + xhigh)。

只有用户**明确**要求时才加:

```bash
ai-claude eval-x "<desc>" "<prompt>" -m sonnet -e high
```

| flag | 作用 | 翻译为 claude 参数 |
|---|---|---|
| `-m <model>` | 覆盖模型(alias 或全名) | `--model <model>` |
| `-e <level>` | 覆盖思考强度 | `--effort <level>` |
