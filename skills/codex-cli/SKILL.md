---
name: codex-cli
description: 用 codex CLI(OpenAI Codex,非交互模式)起独立任务 session,**优先用于开发/实现型任务**。
  支持多 session 并行、按 name 续聊、本地存档(sid/desc/last/full)、worktree 隔离开发。
  触发词:"用 codex 写/做/实现/重构/改"、"让 codex 开发"、"codex 把 X 实现一下"、
  "并行起多个 codex 干 X/Y/Z"、"接着上次 codex 那个 X 继续"、"再开一个 codex 做 Y"。
  当用户想"启动外部 codex 实例(独立上下文)处理实现型任务"时使用。
  方案/分析/审视型任务优先用 `claude-cli` skill。
---

# codex-cli skill

用 codex CLI 起非交互 session、跨调用续聊、多 session 并行。底层走用户自定义 shell 函数 `ai-codex*`,默认走 `~/.codex/config.toml`(gpt-5.5 + xhigh + danger-full-access)。

## 使用场景定位

**codex 是"实现型 agent"——优先派给它做开发**:

| 适合 codex 的任务 | 不适合 codex(改派 claude-cli) |
|---|---|
| 实现一个新函数/模块 | 出技术方案、做架构选型 |
| 重构现有代码 | 评估几种方案的取舍 |
| 加单元测试 | 审 PRD/需求文档 |
| 修 bug、补类型 | 写技术分析/思路梳理 |
| 改文件结构、批量编辑 | 分析现状不动手 |
| 加 CLI flag、加配置项 | 讨论"该怎么做" |

简记:**codex 干活,claude 出方案**。任务里有"实现/写/改/重构/加测试"等动词 → 用 codex;有"分析/方案/思路/审视/评估" → 用 claude。

## 开工扫描(建议)

如果对话上下文里**不清楚现有 session 状态**——比如用户提到某个 name 但你不确定它是否存在,或跨会话恢复完全没有上文——先跑一次:

```bash
ai-sessions
```

如果对话里已经很清楚(刚起的 session、用户明说"新起 X"),**跳过这步直接干**。

## 核心命令

| 场景 | 命令 |
|---|---|
| 新起 session | `ai-codex <name> "<desc>" "<prompt>"` |
| 续聊 session | `ai-codex-c <name> "<prompt>"` |
| 列出所有 session | `ai-sessions` |
| 删除某 session | `ai-rm <name>`(短名歧义时用完整 `codex-<name>`) |

## name + desc 规则

- **name**:kebab-case,短(2-4 词),语义化。例:`add-redis-cache`、`refactor-auth-util`、`fix-payment-race`。**反例**:`task1`、`tmp`、`test`
- **desc**:**必填**,≥ 15 字符,讲清"这个 session 在做什么"
  - 好例:"给 auth 模块加 Redis 缓存避免重复查 DB"、"重构 payment.ts 拆出三个子模块"
  - 反例:"测试"、"看看代码"、"修 bug"

## 提示词五件套(每条 prompt 都应覆盖)

外部 codex **没看过本对话**,prompt 必须自包含:

- **[目标]** 动词开头,要它做什么
- **[背景]** agent 从 cwd 看不出的事(项目阶段、隐性约束、决策由来)
- **[输入]** 让它读哪些文件、跑什么命令(给具体路径,不让猜)
- **[约束]** 不能改什么/不能装什么/输出语言(默认中文)
- **[产出]** 形式(diff 总结/清单)+ 长度(如 "200 字内")

不必死板贴 `[目标]` 这种标签,关键是**五个维度都覆盖**。

## 安全约束(自动追加)

shell 函数自动在每条 prompt 末尾追加:

> 约束:不要执行 git commit 或 git push。

⚠️ codex 默认 `sandbox_mode = danger-full-access`——它**真的会改文件、跑命令**。让它"只分析不改文件"的任务务必显式写"不要修改任何文件"。

---

## 🔥 开发工作流(改文件任务必走 worktree)

当 codex 任务**会修改文件**时,**必须用 git worktree 隔离**,避免污染当前分支。

### 标准 6 步

```bash
# 假设主项目 ~/project/foo,当前在分支 feat/auth
cd ~/project/foo
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# 1. 建 worktree(branch 复用 ai-codex name,加 codex- 前缀)
git worktree add ../foo-codex-<name> -b codex-<name>
cd ../foo-codex-<name>

# 2. 起 codex session,让它改文件
ai-codex <name> "<desc>" "<prompt>"

# 3. (可选)续聊精修
ai-codex-c <name> "<再做点啥>"

# 4. Claude Code 自己审 + commit(safety 约束阻止 codex 自己 commit)
git diff
git status
git add -A
git commit -m "<符合项目风格的 commit message>"

# 5. 让用户审 commit
git log --oneline -5
git show HEAD --stat

# 6. 用户 OK → merge 回原 branch + 清理
cd ../foo
git merge codex-<name>           # 合并到原 branch(不是 main)
git worktree remove ../foo-codex-<name>
git branch -d codex-<name>
```

### 关键规则

- **branch 名**:`codex-<ai-codex 的 name>`,例:`codex-add-redis-cache`
- **worktree 路径**:`<项目根>/../<repo名>-codex-<name>`(并排目录,git 标准做法)
- **commit 由 Claude Code 写**,不让 codex 自己 commit(safety 约束阻止它)
- **merge 目标**:**当前开发分支**,不是 main。先 `git rev-parse --abbrev-ref HEAD` 记住,后面 merge 到它
- **不在 git 仓库** → 跳过 worktree,警告用户"非 git 项目,无法回退"
- **用户明确说"不要 commit"或"先看看"** → 跑到第 3 步停,等用户决定

---

## 🔥 任务调度(多任务时优先并行)

当用户给你多个开发任务时(或一个大任务可拆成多子任务),按以下流程调度:

### Step 1: 列候选任务

清单化:
- 任务 A: <一句话>
- 任务 B: <一句话>
- ...

### Step 2: 检测依赖关系

逐对问:**"完成 A 是否需要 B 的产出?"**

例:
- "给登录加测试" 依赖 "重构登录模块"? → 是,先重构再加测试
- "改 README 措辞" 依赖 "改 utils.ts 拆分"? → 否,无关

### Step 3: 决策

| 情况 | 策略 |
|---|---|
| 全无依赖,N ≤ 5 | **全部并行**,各起一个 worktree |
| 全无依赖,N > 5 | ⚠️ **警告**(不报错):"N=X 任务并行较多,建议拆 2-3 批",然后按用户意愿继续 |
| 部分有依赖 | 先并行无依赖部分,完成后再做依赖部分 |
| 单任务 | 直接跑(可选 worktree) |

**默认优先并行**——只在确有依赖时退化为串行。

### 并行执行的命令模板

```bash
# 假设 3 个无依赖任务
cd ~/project/foo
git worktree add ../foo-codex-task-a -b codex-task-a
git worktree add ../foo-codex-task-b -b codex-task-b
git worktree add ../foo-codex-task-c -b codex-task-c

# 并行起 3 个 codex
( cd ../foo-codex-task-a && ai-codex task-a "<desc>" "<prompt>" ) &
( cd ../foo-codex-task-b && ai-codex task-b "<desc>" "<prompt>" ) &
( cd ../foo-codex-task-c && ai-codex task-c "<desc>" "<prompt>" ) &
wait

# 之后逐个进 worktree 审 + commit + merge
```

### >5 任务的警告输出范例

```
⚠️ 检测到 7 个并行候选任务,超过推荐上限(5)。
   原因:同时跑太多 codex 会:
   - 占用大量 token / 触发限流
   - 控制台输出严重交错,排查困难
   - 任务彼此抢资源(磁盘 IO、API)
   建议:拆成 2 批(4 + 3)或减少范围。要继续吗?[Y/n]
```

---

## 反模式 vs 正模式

❌ 不假设跨 session 共享上下文:
```bash
ai-codex task-a "实现登录 ..."
ai-codex task-b "实现注册,跟 task-a 共用一套 schema"   # task-b 不知道 task-a 是啥
```

✅ 各 session prompt 自包含:
```bash
ai-codex task-a "<desc>" "[目标] 实现登录。[约束] schema 必须满足:user_id/email/password_hash..."
ai-codex task-b "<desc>" "[目标] 实现注册。[约束] schema 必须满足:user_id/email/password_hash...(与 task-a 共享)"
```

---

❌ 续聊时用模糊指代:
```bash
ai-codex-c x "继续刚才那个,再深入一下"
```

✅ 续聊写新增信息 + 具体指令:
```bash
ai-codex-c x "你刚加的 factorial 函数没处理 float 输入,补一个 isinstance 检查并 raise TypeError。"
```

---

❌ 跳过 worktree 直接改主 branch:
```bash
cd ~/project/foo                # 还在 feat/auth 分支
ai-codex add-cache "<desc>" "<prompt>"   # codex 直接改文件,污染 feat/auth
```

✅ worktree 隔离:
```bash
cd ~/project/foo
git worktree add ../foo-codex-add-cache -b codex-add-cache
cd ../foo-codex-add-cache
ai-codex add-cache "<desc>" "<prompt>"
# 改完审 commit,审完 merge 回 feat/auth
```

## 续聊规则

续聊时 codex **已经记着第一轮所有上下文**:
- **不要重复背景**
- 只写**新增信息 + 新指令**
- 续聊可以在主项目或任意 worktree 里跑——session 元数据在主项目集中,`ai-codex-c <name>` 都能找到

## 常见错误 → 修复

| 错误 | 修复 |
|---|---|
| `❌ session 'codex-x' 已存在` | 续聊 `ai-codex-c x "..."` / 重置 `ai-rm codex-x && ai-codex x "..." "..."` |
| `❌ session 'codex-x' 不存在` | 用 `ai-codex x "<desc>" "..."` 新起 |
| `❌ desc 至少 15 字符` | desc 写长,讲清做什么 |
| `❌ name 必须是 kebab-case` | 小写字母+数字+连字符 |
| `command not found: ai-codex` | `source ~/.config/zsh/ai-cli.zsh` 或检查 `~/.zshrc` |
| codex 卡很久不返回 | gpt-5.5 + xhigh + 500K,长任务 1-3 分钟正常 |
| `⚠ 无法抓取 session id` | 看 `.ai-sessions/codex-x/full.log` 排查 |
| worktree 已存在 | `git worktree list` 看占用,先 `git worktree remove` |
| merge 冲突 | 进 worktree 解冲突再 commit,或放弃 worktree 重做 |

## 文件结构(进阶,需要查历史时看)

**所有 session 集中在主项目根的 `.ai-sessions/`**——不管你在主项目里跑还是在 worktree 里跑,session 元数据**永远落主项目**(通过 `git rev-parse --git-common-dir` 找到主 repo)。

```
<主项目根>/.ai-sessions/codex-<name>/
  sid          # session UUID
  desc         # 描述
  last.txt     # 最新一轮的 final message(看总结)
  full.log     # 完整流式输出累加(看过程、工具调用)
```

**为什么集中**:
- worktree 删除时 session 元数据不丢失
- 一个项目内开 N 个 worktree(N 个并行任务),session 列表始终一致
- `ai-sessions` 在任意 worktree 里跑,看到的都是主项目全部 session

`cat <主项目根>/.ai-sessions/codex-<name>/last.txt` 看总结;`cat .../full.log` 看全程(轮次以 `=== Round N @ time ===` 分隔)。

## 进阶:覆盖默认模型/思考(默认不传)

**默认绝对不传** model/effort,走 `~/.codex/config.toml`(gpt-5.5 + xhigh)。

只有用户**明确**要求"用 X 模型 / 高/低思考"时才加 flag:

```bash
ai-codex audit-x "<desc>" "<prompt>" -m gpt-5.4 -e high
```

| flag | 作用 | 翻译为 codex 参数 |
|---|---|---|
| `-m <model>` | 覆盖模型 | `-m <model>` |
| `-e <level>` | 覆盖思考强度 | `-c model_reasoning_effort=<level>` |
