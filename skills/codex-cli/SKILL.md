---
name: codex-cli
description: 用 codex CLI(OpenAI Codex,非交互模式)起独立任务 session,**优先用于开发/实现型任务**,
  尤其擅长**后端/系统编程**(Go/Rust/Java 服务、数据库 schema/migration、并发/分布式、性能优化等)。
  支持多 session 并行、按 name 续聊、本地存档(sid/desc/last/full)、worktree 隔离开发。
  触发词:"用 codex 写/做/实现/重构/改"、"让 codex 开发"、"codex 把 X 实现一下"、"codex 写后端"、
  "并行起多个 codex 干 X/Y/Z"、"接着上次 codex 那个 X 继续"、"再开一个 codex 做 Y"。
  当用户想"启动外部 codex 实例(独立上下文)处理实现型任务"时使用。
  方案/分析/审视型任务优先用 `claude-cli` skill;**前端开发**(React/Vue/CSS/UI 框架/前端工程化)
  优先用 `claude-cli`(claude 在前端领域比 codex 更擅长)。
---

# codex-cli skill

用 codex CLI 起非交互 session、跨调用续聊、多 session 并行。底层走 `agent codex new/c` 子命令(`~/.local/bin/agent` wrapper),默认走 `~/.codex/config.toml`(当前:gpt-5.6-sol + medium + danger-full-access)。

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

### 开发领域分工(很重要,避免错派)

| 领域 | 优先 | 理由 |
|---|---|---|
| **后端**:Go/Rust/Java 服务、数据库 schema/migration、并发/分布式、性能优化、系统编程 | **codex** | codex 在系统级编程、强类型语言、底层优化上更擅长 |
| **前端**:React/Vue/Angular UI 框架、CSS/Tailwind、组件设计、前端工程化(Vite/Webpack)、TypeScript 前端类型 | **claude(改派 claude-cli)** | claude 在前端领域比 codex 更擅长——UI 直觉、组件抽象、CSS 调优都更顺手 |
| **全栈/纯逻辑**:不分前后端(算法、脚本、工具函数) | 默认 codex | 看场景 |

**反例**:用户说"帮我加个 React 组件,样式用 Tailwind",直接派 codex 是次优——应该改派 `claude-cli` skill。

## 开工扫描(建议)

如果对话上下文里**不清楚现有 session 状态**——比如用户提到某个 name 但你不确定它是否存在,或跨会话恢复完全没有上文——先跑一次:

```bash
agent ls
```

如果对话里已经很清楚(刚起的 session、用户明说"新起 X"),**跳过这步直接干**。

## 核心命令

| 场景 | 命令 |
|---|---|
| 新起 session | `agent codex new <name> <desc> <prompt> [-m M] [-e E] [-C dir]` |
| 续聊 session | `agent codex c <name> <prompt> [-m M] [-e E] [-C dir]` |
| 列出所有 session | `agent ls` |
| 删除某 session | `agent rm <name>`(短名歧义时用完整 `codex-<name>`) |

`-m` / `-e` **默认不传**(走本机 config),详见文末「模型 / 思考强度」。

**关于 `-C, --cwd <dir>`**:工作目录可选参数。不传 = 当前 shell PWD;传了 = 函数内先 `cd "$dir"` 再起 codex,session 文件夹也跟着落到 `dir` 所属的项目根。下面 worktree 流程用 `-C` 替代手动 cd,代码更短。

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

## 安全约束(仅 codex 自动追加)

shell 函数**只对 codex** 在 prompt 末尾自动追加:

> 约束:
> - 不要执行 git commit 或 git push。
> - 不要调用 agent 命令起新 session,避免任务套娃。

第二条防 codex 在 `danger-full-access` 下看到 PATH 里有 `agent` 就主动调,搞出"agent 起 codex,codex 又起 agent..."的无限嵌套。**这是 codex 的硬规则,即使它是被外部 claude 起的(claude 是协作 peer,允许它起 codex 子任务)也一样——claude → codex 这一层之后就到底,codex 不会再起新 session**。

> 对照:`agent peer new/c`（`agent claude` 兼容别名）**不追加 safety suffix**，只注入 peer 嵌套规则。claude 当协作者用，完整能力放开；约束自己写进 prompt。详见 `claude-cli` skill。

⚠️ codex 默认 `sandbox_mode = danger-full-access`——它**真的会改文件、跑命令**。让它"只分析不改文件"的任务务必显式写"不要修改任何文件"。

---

## 🔥 开发工作流(改文件任务必走 worktree)

当 codex 任务**会修改文件**时,**必须用 git worktree 隔离**,避免污染当前分支。

### 标准 6 步

```bash
# 假设主项目 ~/project/foo,当前在分支 feat/auth
cd ~/project/foo
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# 1. 建 worktree(branch 复用 agent name,加 codex- 前缀)
git worktree add ../foo-codex-<name> -b codex-<name>

# 2. 起 codex session,让它改文件(-C 直接指 worktree,省一步 cd)
agent codex new <name> "<desc>" "<prompt>" -C ../foo-codex-<name>

# 3. (可选)续聊精修(续聊也走 -C 进同一个 worktree)
agent codex c <name> "<再做点啥>" -C ../foo-codex-<name>

# 4. Claude Code 自己审 + commit(safety 约束阻止 codex 自己 commit)
cd ../foo-codex-<name>
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

- **branch 名**:`codex-<agent name>`,例:`codex-add-redis-cache`
- **worktree 路径**:`<项目根>/../<repo名>-codex-<name>`(并排目录,git 标准做法)
- **`-C dir` 替代 cd**:不用先手动 cd 进 worktree,`agent codex new ... -C ../foo-codex-<name>` 一行搞定
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
# 假设 3 个无依赖任务,3 个 worktree
cd ~/project/foo
git worktree add ../foo-codex-task-a -b codex-task-a
git worktree add ../foo-codex-task-b -b codex-task-b
git worktree add ../foo-codex-task-c -b codex-task-c

# 并行起 3 个 codex,各自 -C 指目标 worktree(不用 cd 也不用子 shell)
agent codex new task-a "<desc>" "<prompt>" -C ../foo-codex-task-a &
agent codex new task-b "<desc>" "<prompt>" -C ../foo-codex-task-b &
agent codex new task-c "<desc>" "<prompt>" -C ../foo-codex-task-c &
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
agent codex new task-a "<desc>" "实现登录 ..."
agent codex new task-b "<desc>" "实现注册,跟 task-a 共用一套 schema"   # task-b 不知道 task-a 是啥
```

✅ 各 session prompt 自包含:
```bash
agent codex new task-a "<desc>" "[目标] 实现登录。[约束] schema 必须满足:user_id/email/password_hash..."
agent codex new task-b "<desc>" "[目标] 实现注册。[约束] schema 必须满足:user_id/email/password_hash...(与 task-a 共享)"
```

---

❌ 续聊时用模糊指代:
```bash
agent codex c x "继续刚才那个,再深入一下"
```

✅ 续聊写新增信息 + 具体指令:
```bash
agent codex c x "你刚加的 factorial 函数没处理 float 输入,补一个 isinstance 检查并 raise TypeError。"
```

---

❌ 跳过 worktree 直接改主 branch:
```bash
cd ~/project/foo                # 还在 feat/auth 分支
agent codex new add-cache "<desc>" "<prompt>"   # codex 直接改文件,污染 feat/auth
```

✅ worktree 隔离 + `-C` 切目录:
```bash
cd ~/project/foo
git worktree add ../foo-codex-add-cache -b codex-add-cache
agent codex new add-cache "<desc>" "<prompt>" -C ../foo-codex-add-cache
# 改完审 commit,审完 merge 回 feat/auth
```

## 长 prompt 走 -f 文件(避免 shell 解析炸)

短 prompt(一两句话、没特殊字符)直接用位置参数 `<prompt>`。**以下任一情况必须走 `-f`**:

- prompt 含反引号 `` ` ``、`$`、`&` 等(bash 会解析成命令替换 / 变量展开 → prompt 内容被破坏)
- prompt 以 `-` 开头(会被当成 flag)
- prompt 较长(几行以上)

### `-f` 的标准用法

```bash
# 1. heredoc 必须 'EOF' 带单引号(禁止 shell 展开)
cat > ~/tmp/agent-prompt-add-cache.md <<'EOF'
[目标] ...
prompt 里随便用 ` $ {} 都安全
EOF

# 2. 起 session
agent codex new add-cache "<desc>" -f ~/tmp/agent-prompt-add-cache.md -C ../foo-codex-add-cache
```

`-f` 文件会自动 archive 到 `<session>/prompt.md`(new)或 `prompt-round-N.md`(续聊),复盘时直接看 session 目录就行,不用回头翻 `~/tmp`。

prompt 文件位置约定:**`~/tmp/agent-prompt-<name>[-rN].md`**(放 `~/tmp/` 用完不删,留底复盘;符合 CLAUDE.md 的 `~/tmp` 约定)。

## 续聊规则

续聊时 codex **已经记着第一轮所有上下文**:
- **不要重复背景**
- 只写**新增信息 + 新指令**
- 续聊可以在主项目或任意 worktree 里跑——session 元数据在主项目集中,`agent codex c <name>` 都能找到
- 续聊也支持 `-f`,长续聊 prompt 也建议走文件

## 常见错误 → 修复

| 错误 | 修复 |
|---|---|
| `❌ session 'codex-x' 已存在` | 续聊 `agent codex c x "..."` / 重置 `agent rm codex-x && agent codex new x "..." "..."` |
| `❌ session 'codex-x' 不存在` | 用 `agent codex new x "<desc>" "..."` 新起 |
| `❌ desc 至少 15 字符` | desc 写长,讲清做什么 |
| `❌ name 必须是 kebab-case` | 小写字母+数字+连字符 |
| `❌ -f 文件不存在 / 为空` | 检查路径或 heredoc 是否真写了内容 |
| `❌ 不能同时传 <prompt> 位置参数和 -f file` | 二选一 |
| `❌ 未知参数: -xxx` | 可能是 prompt 以 `-` 开头被误判,改走 `-f` |
| shell 报反引号 / `$` 展开错误 | prompt 含特殊字符,改走 `-f` 文件 |
| `command not found: agent` | 重跑 install.sh,或检查 `~/.local/bin/agent` 是否在 PATH |
| codex 卡很久不返回 | 长任务 1-3 分钟正常(思考强度调高会更久);**5 分钟无输出 wrapper 会自动 kill** |
| `❌ -m 不支持 'xxx'` / `❌ -e 不支持 'xxx'` | 传了白名单外的值,按报错提示的可选值改;要用别的值得改 `~/.codex/config.toml` |
| `⚠ codex exit code: 137` | **watchdog 自动 kill**(5 分钟无输出),诊断包在 `~/.ai-sessions-incidents/`,用 `agent incidents` 查看 |
| `⚠ 无法抓取 session id` | 看 `.ai-sessions/codex-x/full.log` 排查 |
| worktree 已存在 | `git worktree list` 看占用,先 `git worktree remove` |
| merge 冲突 | 进 worktree 解冲突再 commit,或放弃 worktree 重做 |

## Watchdog(自动防卡死,你通常不用管)

wrapper 自带 watchdog:120s 无新输出警告,5 分钟无新输出自动 kill + 收集诊断。**正常使用不会触发**。如果用户报告"codex 卡很久",或者 codex 返回 exit code 137,跑 `agent incidents` 看诊断:

```bash
agent incidents                  # 列全部
agent incidents <关键字>         # 看某次详情
```

诊断包路径在 `~/.ai-sessions-incidents/<时间戳>-<cli>-<name>/`,含 `stack.sample.txt`(Node + Rust 调用栈)等。可以直接 `cat` 读分析,或者整包发给用户/上游。

## 文件结构(进阶,需要查历史时看)

**所有 session 集中在主项目根的 `.ai-sessions/`**——不管你在主项目里跑还是在 worktree 里跑,session 元数据**永远落主项目**(通过 `git rev-parse --git-common-dir` 找到主 repo)。

```
<主项目根>/.ai-sessions/codex-<name>/
  sid                    # session UUID
  desc                   # 描述
  last.txt               # 最新一轮的 final message(看总结)
  full.log               # 完整流式输出累加(看过程、工具调用)
  prompt.md              # -f 传入的原 prompt(new 时 archive)
  prompt-round-N.md      # 续聊每轮 -f prompt archive
```

**为什么集中**:
- worktree 删除时 session 元数据不丢失
- 一个项目内开 N 个 worktree(N 个并行任务),session 列表始终一致
- `agent ls` 在任意 worktree 里跑,看到的都是主项目全部 session

`cat <主项目根>/.ai-sessions/codex-<name>/last.txt` 看总结;`cat .../full.log` 看全程(轮次以 `=== Round N @ time ===` 分隔)。

## 模型 / 思考强度(`-m` / `-e`)——默认绝对不传

**默认绝对不传** `-m` / `-e`。不传 = 走 `~/.codex/config.toml`(当前 gpt-5.6-sol + medium),这是绝大多数情况下正确的做法。

**只有用户明确要求换档时才传**——比如用户说"用 luna 跑"、"这个要高思考"、"快速过一遍就行"。**不要自己按任务性质替用户决定用什么模型/思考强度**:成本和耗时的取舍是用户的决策,不是你的。

### 可选值(白名单,传别的直接报错)

| flag | 可选值 | 说明 |
|---|---|---|
| `-m` | `gpt-5.6-sol`、`gpt-5.6-luna`、`gpt-5.6-terra` | 不传 = config 默认(gpt-5.6-sol) |
| `-e` | `low` `medium` `high` `xhigh` `max` | 不传 = config 默认(medium) |

codex 本身还认识 `none`/`minimal`/`ultra` 三档 effort 和十几个 gpt-5.x 模型,但 wrapper **刻意只开放上面这些**。传白名单外的值会被本地拦下并列出可选值,不会打到服务端。用户要用别的值 → 让他改 `~/.codex/config.toml`。

### 续聊会自动沿用,不用重复传

`new` 时传的 model/effort 会记进 session(`.ai-sessions/codex-<name>/model` 和 `effort`),**续聊自动沿用同一档**——不会出现"首轮 luna 高思考、续聊悄悄掉回 sol medium"的跨轮换脑子。

续聊也能显式传 `-m`/`-e` 覆盖,覆盖后成为该 session 之后各轮的新默认。

```bash
# 用户明说要换档
agent codex new audit-x "审计 payment 模块的并发安全" "<prompt>" -m gpt-5.6-luna -e xhigh

# 续聊不用重复传,自动还是 luna + xhigh
agent codex c audit-x "刚才漏了退款路径,补一下"

# 续聊想临时提档
agent codex c audit-x "<prompt>" -e max
```

## 类型档案（review / web 等）

声明式类型使用与 codex 相同的平铺入口；先用 `agent type ls` 查看当前可用类型和默认档位：

```bash
agent <type> new <name> "<desc>" "<prompt>" [-m M] [-e E] [-C dir]
agent <type> c <name> "<prompt>" [-m M] [-e E] [-C dir]
```

- `review`：方案审查，固定只读沙箱 + max；只产出带具体失败场景的分级审查意见。
- `web`：网页采集，把正文、图片和 manifest 资产化到指定目录；未指定时落 `~/reference/`。

```bash
agent review new review-cache "审查缓存改造方案的风险和失败场景" -f ~/tmp/cache-plan.md -C ~/project/myrepo
agent web new collect-docs "采集官方文档并整理成本地 Markdown 参考资料" "抓取 https://example.com/docs 全模块" -C ~/reference
```

### 复盘回写纪律（飞轮）

类型化 session 失败或产出不达标时，主对话必须归因并回答：**"这是一次性事故，还是可固化成规则的系统性坑？"**

- 系统性坑 → 当场修改该类型的 `inject.md`（注入提示词），提交时写明来源场景，再重跑任务
- 一次性事故 → 直接重试，不动规则
- 新规则标注来源场景；场景消失（依赖升级/坑已根治）就删规则，不留墓碑
- 提示词修改永远走 git 提交，不做无人值守的自动改写

