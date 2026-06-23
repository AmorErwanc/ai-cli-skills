---
name: claude-cli
description: 用 claude CLI(外部 Claude 实例,非交互 -p 模式)起独立任务 session。
  外部 claude 是你(Claude Code)的**协作 peer**——跟你共享同一套系统提示词和 CLAUDE.md,
  能跨项目读代码、出方案、追踪进度,也能自己动手改文件。**前端开发(React/Vue/CSS/UI
  框架/前端工程化)优先 claude,claude 在这些领域比 codex 更擅长**。需要并发改代码避免
  冲突时可以自己起 codex 在 worktree 里干。支持多 session 并行、按 name 续聊、本地存档。
  触发词:"让 claude 帮我看一下"、"起一个 claude 协助 X"、"用 claude 跨项目协调 A 和 B"、
  "claude 出方案对比"、"让 claude 接管 X 任务"、"用 claude 写前端"、"接着上次 claude 那个 X 继续"。
  当用户想"找一个独立 claude 协作伙伴(而不只是工具)处理某个独立工作流"时使用。
  后端/系统编程任务(Go/Rust/Java/数据库 schema/分布式等)直接用 `codex-cli` skill。
  注意:本对话里的"你"就是 Claude Code,用户说"你帮我分析"通常不是触发本 skill;
  只有明确表达"起一个外部的、独立的 claude"或"在后台让 claude"才用。
---

# claude-cli skill

外部 claude peer 默认走 `~/.claude/settings.json`(Opus 4.7 1M + xhigh + bypassPermissions)。底层用 `agent claude new/c` 子命令(详见下方命令清单)。

## 定位:外部 claude 是 Claude Code 的「协作 peer」

跟 codex 当"工具"用不一样——**外部 claude 是你的平级协作者**,能独立扛一段工作流。适合派给它的场景:

- **跨项目协调**:本地有 A 和 B 两个项目,A 改了共用表结构需要 B 配合。让外部 claude 直接读 B 项目代码、出 A+B 双边方案、追踪两边进度,**也可以顺手帮 B 改基础东西**(部署 yaml、配置文件、文档、单文件小改之类,不是大开发量的可以自己干)
- **方案/审视/评估**:出技术方案、做架构选型、对比几种方案的取舍、审 PRD/需求文档
- **独立工作流接管**:某个任务需要一段完整的"调研 → 方案 → 落地"链路,把整个链路交给 claude 全程跟进

简记:**claude 是协作伙伴,codex 是干活工具**。

### 开发领域分工(很重要,避免错派)

| 领域 | 优先 | 理由 |
|---|---|---|
| **前端**:React/Vue/Angular UI 框架、CSS/Tailwind、组件设计、前端工程化(Vite/Webpack)、TypeScript 前端类型 | **claude** | claude 在前端领域比 codex 更擅长——UI 直觉、组件抽象、CSS 调优都更顺手 |
| **后端**:Go/Rust/Java 服务、数据库 schema/migration、并发/分布式、性能优化、系统编程 | **codex** | codex 在系统级编程、强类型语言、底层优化上更擅长 |
| **全栈/纯逻辑**:不分前后端的(算法、脚本、工具函数) | 都行 | 看场景,默认 codex(因为它更"干活") |

**反例**:用户说"帮我加个 React 组件",直接派 codex 是次优——派 claude 协作更合适。

不适合派给 claude(直接用 codex):
- 单纯后端开发(写 Go handler、加数据库表、加测试、修 bug)——这些任务没必要绕 claude 一道,直接 `agent codex new`

## 🔥 工作目录必须显式切到目标项目(`-C` 参数)

跨项目协作的**第一硬规则**:claude 的 cwd 决定它能读什么。**你自己的 cwd 跟 claude 任务的 cwd 通常不是一回事**。

典型场景:
- 你当前 cwd 在 `~/project/A`(用户跟你聊的就是 A 项目)
- 任务需要 claude 去 B 项目(`~/project/B`)看代码、出双边方案,甚至直接帮 B 改一些基础东西(部署 yaml、配置文件、文档、单文件小改)
- ❌ 错误:`agent claude new ...` 不传 `-C`,claude 起来的 cwd = A,看不到 B 的代码,更没法改 B
- ✅ 正确:`agent claude new <name> "<desc>" "<prompt>" -C ~/project/B`,claude 起来的 cwd = B,既能读 B 的代码也能直接改 B 的文件

**判断什么时候要传 `-C`**:
- claude 主要要读 / 协调的项目 ≠ 你当前 cwd 所在项目 → **必须传 `-C` 指向目标项目根**
- claude 要同时读 A 和 B → 选**主战场**那个项目作为 cwd(通常是要改的一方),然后在 prompt 里给另一方的绝对路径
- claude 不需要读任何项目代码(纯方案讨论)→ 不传 `-C` 也行,但**建议显式传一个有意义的目录**(比如 `/tmp` 或 `~/tmp`)避免污染当前项目的 `.ai-sessions/`

> 副作用:`-C dir` 会让 session 文件夹也落到 `dir` 所属的项目根。这是预期行为——session 记录跟它服务的项目绑在一起,符合直觉。

## 改代码:默认自己干,并发场景才起 codex

claude peer 跟你共享同一套系统提示词和 CLAUDE.md,**信任度本来就一致**。读项目代码、出方案、动手改 1-2 个文件这种**单线程协作场景,peer 自己干就好,不必绕 codex**。

什么时候应该让 peer 起 `agent codex new` 让 codex 来改:

- **并发隔离**:peer 要并行起多个改代码子任务,或者同时你/用户也在 main 上动 → 起 codex 走 worktree 避免冲突(这是 codex worktree 的真实理由,不是信任问题)
- **大量批量改文件**:几十个文件级别的重构,起 codex 在 worktree 干完一次性合,比 peer 在 main 上零散改更稳
- **小改 1-2 个文件**:peer 直接动手就行

典型链路(A 改表结构 + B 跟改代码,**单线程协作场景**):
1. peer 读 A 的 migration、读 B 的 ORM/调用方代码 → 出双边方案(A 改什么、B 改什么)
2. 你看完方案,觉得 OK → 让 peer 继续推进
3. peer 自己改 A 和 B 的代码(数量不大 + 没人在并发改 → 不需要 worktree)
4. peer 把改动总结回报给你
5. 你审 diff、commit、回报用户

> codex 不会自己再起新 agent session(safety 约束),所以即使 peer 起了 codex,最多到 claude → codex 两层,不会无限套娃。

### 你调 peer 时的 hint

如果你**预判**这次任务里 peer 会需要做并发或批量改代码(典型:用户已经在 main 上有未提交改动 + 任务要改多文件),在 prompt 里加一句简短 hint:

> "改代码涉及并发(可能跟用户或并行任务撞 main),按 codex-cli skill 起 codex + worktree 干"

peer 自己读 `codex-cli` skill 处理细节,你不必在 claude prompt 里贴 codex 命令模板。

## 开工扫描(建议)

如果对话上下文里**不清楚现有 session 状态**——比如用户提到某个 name 但你不确定它是否存在,或跨会话恢复完全没有上文——先跑一次:

```bash
agent ls
```

如果对话里已经很清楚(刚起的 session、用户明说"新起 X"),**跳过这步直接干**。

## 核心命令

| 场景 | 命令 |
|---|---|
| 新起 session | `agent claude new <name> <desc> (<prompt> \| -f file) [-C dir]` |
| 续聊 session | `agent claude c <name> (<prompt> \| -f file) [-C dir]` |
| 列出所有 session | `agent ls [codex\|claude]`(可按 cli 过滤) |
| 删除某 session | `agent rm <name>`(短名歧义时用完整 `claude-<name>`) |

**关于 `-C, --cwd <dir>` 和 `-f <file>`**:
- `-C` 工作目录可选;不传 = 当前 shell PWD;传了 = 函数内先 `cd "$dir"` 再起,session 文件夹也跟着落到 `dir` 所属的项目根
- `-f` 从文件读 prompt,跟位置参数 `<prompt>` 互斥;含反引号 / `$` / 以 `-` 开头 / 较长的 prompt 都走 `-f`

## name + desc 规则

- **name**:kebab-case,短(2-4 词),语义化。例:`plan-auth-redesign`、`eval-cache-options`、`audit-pr-123`
- **desc**:**必填**,≥ 15 字符,讲清"这个 session 在做什么"
  - 好例:"评估 Redis vs Memcached 在缓存层的取舍"、"梳理登录改造的方案与影响范围"
  - 反例:"看看"、"想一下"

## 提示词五件套(参考,不强求全覆盖)

外部 claude **没看过本对话**,prompt 要尽量自包含。下面五个维度按需挑用——简单需求一两条够,复杂任务才用全:

- **[目标]** 动词开头,要它做什么(如"评估"、"梳理"、"对比"、"分析")。通常**必备**
- **[背景]** agent 从 cwd 看不出的事(项目阶段、隐性约束、决策由来)。**协作型任务建议给**
- **[输入]** 让它读哪些文件、跑什么命令(给具体路径,不让猜)。**协作 / 跨项目场景常用**
- **[约束]** 不能改什么(方案类默认 **"只分析,不改任何文件"**)、输出语言。**按需**
- **[产出]** 形式(方案对比表/清单/利弊分析)+ 长度(如 "500 字内")。**如果你自己也不确定要什么,这项可以省**——让 claude 自己判断更合适的产出形式

简单协作场景(比如"看一眼 B 项目的 ORM 文件,告诉我有几个 model 用到 user 表"),一个 [目标] + 一个 [输入] 就够,不必勉强凑五件套。

## Prompt 原样透传(不追加任何约束)

**`agent claude new/c` 把 prompt 完整原样传给 claude,末尾不追加任何 safety suffix**。claude 在这套工作流里被当作"协作者"使用,完整能力交给它——包括 git commit/push、起新 agent session 等,都不自动禁。

代价:任何想加的约束你都得**自己写进 prompt**。常见模板:

- 只读不改文件: `[约束] 只分析,不要修改任何文件。`
- 不要提交: `[约束] 不要 git commit/push。`
- 不让它再套娃: `[约束] 不要调用 agent 命令起新 session。`

peer 默认 `bypassPermissions`,**会按需改文件**——这是协作者预期能力,不是 hazard。纯方案/分析任务记得写"只分析不改"约束就行。

> 对照:`agent codex new/c` **保留** safety suffix(自动加"不要 git commit/push"和"不要套娃"两条),因为 codex 是被调工具,默认更危险(`danger-full-access`)。详见 `codex-cli` skill。

## 长 prompt 走 -f 文件(避免 shell 解析炸)

短 prompt(一两句话、没特殊字符)直接用位置参数。**以下任一情况必须走 `-f`**:

- prompt 含反引号 `` ` ``、`$`、`&` 等(bash 会解析成命令替换 / 变量展开 → prompt 内容被破坏)
- prompt 以 `-` 开头(会被当成 flag)
- prompt 较长(几行以上,方案审查类经常超出)

### `-f` 的标准用法

```bash
# 1. heredoc 必须 'EOF' 带单引号(禁止 shell 展开)
cat > ~/tmp/agent-prompt-eval-cache.md <<'EOF'
[目标] 评估 Redis vs Memcached 在缓存层的取舍
[背景] 我们的 $TPS 大约 5000,markdown 代码块的反引号 `code` 都安全
EOF

# 2. 起 session
agent claude new eval-cache "<desc>" -f ~/tmp/agent-prompt-eval-cache.md -C ~/project/myrepo
```

`-f` 文件会自动 archive 到 `<session>/prompt.md`(new)或 `prompt-round-N.md`(续聊),复盘时直接看 session 目录就行,不用回头翻 `~/tmp`。

prompt 文件位置约定:**`~/tmp/agent-prompt-<name>[-rN].md`**(放 `~/tmp/` 用完不删,留底复盘)。

## 反模式 vs 正模式

❌ 不假设跨 session 共享上下文:
```bash
agent claude new plan-a "<desc>" "评估方案 A: ..."
agent claude new plan-b "<desc>" "评估方案 B,跟 A 对比"        # B 不知道 A 是啥
```

✅ 各 session prompt 自包含:
```bash
agent claude new plan-a "<desc>" "[目标] 评估方案 A: <完整描述>"
agent claude new plan-b "<desc>" "[目标] 评估方案 B: <完整描述>。与 A 的差异:<列出来>"
# 之后你自己拿两个结果做对比,不让 B 知道 A
```

---

❌ 续聊时用模糊指代:
```bash
agent claude c x "继续刚才那个"
```

✅ 续聊写新增信息 + 具体指令:
```bash
agent claude c x "你方案 A 里说要用 Redis Pub/Sub,但我们的运维不支持 Pub/Sub。换个等价方案。"
```

---

## 并行评估方案的典型场景

让 claude 并行评估 3 个方案,然后你自己汇总对比:

```bash
agent claude new plan-a "评估方案 A" "[目标] 评估方案 A: <完整描述>。[约束] 只分析。[产出] 优劣表,300 字内。" &
agent claude new plan-b "评估方案 B" "[目标] 评估方案 B: <完整描述>。[约束] 只分析。[产出] 优劣表,300 字内。" &
agent claude new plan-c "评估方案 C" "[目标] 评估方案 C: <完整描述>。[约束] 只分析。[产出] 优劣表,300 字内。" &
wait

# 然后你自己读 3 个 last.txt,做整合对比给用户
cat .ai-sessions/claude-plan-{a,b,c}/last.txt
```

prompt 复杂时各自走 `-f` 文件,例如 `-f ~/tmp/agent-prompt-plan-a.md`。并行上限同 codex-cli:N ≤ 5 直接跑,N > 5 警告"任务多,建议拆批"。

## 续聊规则

续聊时 claude **已经记着第一轮所有上下文**:
- **不要重复背景**
- 只写**新增信息 + 新指令**
- 续聊也支持 `-f`,长续聊 prompt 也建议走文件

## 常见错误 → 修复

| 错误 | 修复 |
|---|---|
| `❌ session 'claude-x' 已存在` | 续聊 `agent claude c x "..."` / 重置 `agent rm claude-x && agent claude new x "..." "..."` |
| `❌ session 'claude-x' 不存在` | 用 `agent claude new x "<desc>" "..."` 新起 |
| `❌ desc 至少 15 字符` | desc 写长 |
| `❌ name 必须是 kebab-case` | 小写字母+数字+连字符 |
| `❌ -f 文件不存在 / 为空` | 检查路径或 heredoc 是否真写了内容 |
| `❌ 不能同时传 <prompt> 位置参数和 -f file` | 二选一 |
| `❌ 未知参数: -xxx` | 可能是 prompt 以 `-` 开头被误判,改走 `-f` |
| shell 报反引号 / `$` 展开错误 | prompt 含特殊字符,改走 `-f` 文件 |
| `command not found: agent` | 重跑 install.sh,或检查 `~/.local/bin/agent` 是否在 PATH |
| claude 卡很久不返回 | Opus 4.7 1M + xhigh,长任务 1-5 分钟正常;**5 分钟无输出 wrapper 会自动 kill** |
| `⚠ claude exit code: 137` | **watchdog 自动 kill**(5 分钟无输出),诊断包在 `~/.ai-sessions-incidents/`,用 `agent incidents` 查看 |
| 输出疑似不完整 | `-p` 默认 text format 只输出 final message;看过程读 `full.log` |

## 文件结构

**所有 session 集中在主项目根的 `.ai-sessions/`**——无论在主项目还是 worktree 里跑,session 元数据都落主项目(通过 `git rev-parse --git-common-dir` 定位)。

```
<主项目根>/.ai-sessions/claude-<name>/
  sid                    # session UUID(预生成)
  desc                   # 描述
  last.txt               # 最新一轮的 final message
  full.log               # 完整对话累加
  prompt.md              # -f 传入的原 prompt(new 时 archive)
  prompt-round-N.md      # 续聊每轮 -f prompt archive
```

worktree 删除不影响 session;`agent ls` 在任意位置都看到完整列表。

## 进阶:覆盖默认模型/思考(默认不传)

**默认绝对不传** model/effort,走 `~/.claude/settings.json`(Opus 4.7 1M + xhigh)。

只有用户**明确**要求时才加:

```bash
agent claude new eval-x "评估缓存方案在低延迟场景下的可行性" "<prompt>" -m sonnet -e high
```

| flag | 作用 | 翻译为 claude 参数 |
|---|---|---|
| `-m <model>` | 覆盖模型(alias 或全名) | `--model <model>` |
| `-e <level>` | 覆盖思考强度 | `--effort <level>` |
