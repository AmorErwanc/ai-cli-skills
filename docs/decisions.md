# 项目决策记录（Decision Log）

> 所有架构决策（ADR）统一记在本文件。**最新在最上面**：新增时索引表加在最上一行，正文小节插在最前。
> 本文件是「为什么这么设计」的单点事实源，不承担最新字段表职责。新增 / 修改前看文末「记录规范」。

## 索引

| 编号 | 标题 | 状态 | 决策日期 | 最近更新 | 标签 |
|---|---|---|---|---|---|
| [ADR-009](#adr-009) | `-m`/`-e` 收窄成白名单 + 续聊沿用 + claude 强制 1M 变体 | Accepted | 2026-07-14 | 2026-07-14 | 参数设计 / 防呆 |
| [ADR-008](#adr-008) | claude -p 走 stream-json,过程流式输出跟 codex 一致 | Accepted | 2026-06-23 | 2026-06-23 | UX / 工具一致性 |
| [ADR-007](#adr-007) | 套娃 codex 用 shell `&`,不用 Bash tool `run_in_background:true` | Accepted | 2026-06-23 | 2026-06-23 | 套娃 / 进程模型 |
| [ADR-006](#adr-006) | claude 套娃硬规则通过 prompt 注入,不是 SKILL.md 教学 | Accepted | 2026-06-23 | 2026-06-23 | 提示词注入 / 协作 peer |
| [ADR-005](#adr-005) | 关闭 claude wrapper 的 watchdog | Accepted | 2026-06-23 | 2026-06-23 | 协作 peer / 资源管理 |
| [ADR-004](#adr-004) | claude=前端开发优先,codex=后端开发优先 | Accepted | 2026-06-23 | 2026-06-23 | 工具分工 |
| [ADR-003](#adr-003) | claude=协作 peer,codex=工具(差异化定位 + safety suffix 差异) | Accepted | 2026-06-22 | 2026-06-23 | 角色定位 / 安全约束 |
| [ADR-002](#adr-002) | 移除顶层 `agent()` shell 函数,wrapper 是唯一入口 | Accepted | 2026-06-22 | 2026-06-22 | 函数管理 / shell snapshot |
| [ADR-001](#adr-001) | 统一入口 `agent` 命令,移除 8 个 `ai-*` 老命令 | Accepted | 2026-06-22 | 2026-06-22 | CLI 入口 / UX |

---

<a id="adr-009"></a>

## ADR-009 · `-m`/`-e` 收窄成白名单 + 续聊沿用 + claude 强制 1M 变体

- **状态**：Accepted
- **决策日期**：2026-07-14
- **最近更新**：2026-07-14
- **标签**：参数设计 / 防呆
- **关联代码**：`shell/ai-cli.zsh`（`_ai_validate_effort` / `_ai_validate_codex_model` / `_ai_resolve_claude_model` / `_ai_save_session_opts`,以及四个 `_agent_*_new|c` 的参数解析）
- **关联文档**：`README.md`（模型/思考强度段）+ 两份 SKILL.md（文末「模型 / 思考强度」段）
- **关联决策**：—

### 背景

`-m`（模型）/ `-e`（思考强度）两个 flag 一直存在,但处于半成品状态,盘出三个问题:

**1. 取值没有任何校验,也没有可选值清单。** 帮助文档只写了 `low/medium/high/xhigh/max`,但那只是拍脑袋写的,没人核对过两个 CLI 到底吃什么。实测(挖二进制 + 真跑)才发现真实枚举是:

| CLI | 实际支持的 effort |
|---|---|
| codex | `none` `minimal` `low` `medium` `high` `xhigh` `max` `ultra` |
| claude | `low` `medium` `high` `xhigh` `max`(官方 `--help` 口径) |

模型侧同理:codex 认识十几个 gpt-5.x(`gpt-5.6-sol/luna/terra`、`gpt-5.5-pro`、`gpt-5.1-codex-max`…),claude 认识 alias + `[1m]` 变体 + 一堆全名。**全都没有清单,传什么都往下透传**,错值要等打到服务端才炸。

**2. 续聊完全不接受这两个 flag。** `_agent_codex_c` / `_agent_claude_c` 的参数解析里根本没有 `-m`/`-e`。后果:首轮 `-m gpt-5.6-luna -e high` 起的 session,一续聊就回落 config 默认(`gpt-5.6-sol` + `medium`)——**同一个 session 跨轮换了脑子,且无任何提示**。

**3. claude 显式指定模型会导致上下文降级。** 本机默认是 `opus[1m]`(1M 长上下文)。而裸 alias `opus` 拿到的是标准上下文窗口。也就是说 `-m opus` 这个看起来"没换模型"的操作,实际把上下文从 1M 悄悄缩回标准档——纯粹的能力降级,无提示。

另外文档里的默认值描述早已过时(写 codex "gpt-5.5 + xhigh"、claude "Opus 4.7 + xhigh",实际是 `gpt-5.6-sol` + `medium` / `opus[1m]` + 未配 effort)。

### 决策

**a. 白名单收窄,传错本地即报错**

| | `-m` | `-e` |
|---|---|---|
| codex | `gpt-5.6-sol`、`gpt-5.6-luna` | `low` `medium` `high` `xhigh` `max` |
| claude | `opus`、`sonnet`、`fable` | 同上 |

刻意**不开放** codex 独有的 `none`/`minimal`/`ultra` 和其余模型:档位铺太开只会让调用方选择困难、选错。想用别的值 → 改本机 config,或直接用原生 CLI。白名单外的值本地拦下并列出可选值,不透传。

**b. 默认不传,只有用户明说才传**

不传 = 走本机 config,这是默认且推荐路径。两份 SKILL.md 明确写"**不要自己按任务性质替用户决定用什么模型/思考强度**——成本和耗时的取舍是用户的决策"。**没有**给 AI 一张"什么任务用什么档"的决策表(见替代方案 B)。

**c. 续聊沿用首轮**

`new` 时的 model/effort 落到 `.ai-sessions/<cli>-<name>/{model,effort}`,续聊不传就读回来沿用;显式传则覆盖**并更新记录**,成为之后各轮的新默认(换档就是换了,不是只换一轮)。没传过就没这两个文件 = 该 session 一直走 config。

> **两条实现约束(codex 独立审查抓出来的,踩过才知道)**:
> 1. **写盘必须在所有校验通过之后**。初版把 `_ai_save_session_opts` 写在校验前,结果续聊传一个白名单外的模型 → 非法值先落盘、再被拒 → 之后每轮续聊都读回这个脏值、每轮都失败,**session 直接报废**,用户不手动 `rm` 救不回来。
> 2. **沿用回来的值也要再校验一次**。只校验显式传入的值是不够的——session 文件可能被手改,或是旧版本遗留的脏数据,不校验就直接透传给 CLI。校验失败时提示该值来自哪个文件、删掉即可重置。

**d. claude 三个 alias 强制映射到 `[1m]` 变体**

`opus` → `opus[1m]`、`sonnet` → `sonnet[1m]`、`fable` → `fable[1m]`。session 里存**原始 alias**(`sonnet`),不存映射后的值——续聊读回来还要再过一次白名单校验。

实现上顺带把 `${=extra}` 字符串拼接改成**数组**(`local -a extra=()`):模型名 `opus[1m]` 含方括号,zsh word-split 展开容易踩 glob 坑,数组展开是安全的。

### 后果

**正面**
- 传错值本地立刻报错并列出可选,不再等服务端 400
- 同一 session 跨轮不再换脑子——`session` 的语义终于成立
- `-m opus` 不再意外把上下文从 1M 缩回标准档
- 白名单小到能一眼记住(2 个 codex 模型 / 3 个 claude 模型 / 5 档 effort)
- 顺带订正了 README + 两份 SKILL 里过时的默认值描述

**负面 / 兼容性**
- 白名单是**硬编码**的:模型换代(gpt-5.7 / opus-4-9 出来)必须手改 `_ai_validate_codex_model` 等函数,忘了改就用不上新模型。这是刻意的取舍——宁可到期手动更新,也不要一个谁都不校验的黑洞
- codex 的 `none`/`minimal`/`ultra` 三档确实有场景(机械批量改动用 minimal 省时省钱、真难的架构题用 ultra),现在够不着。等真有需求再加,不预先开
- claude 强制 `[1m]` 意味着**无法**通过 `-m` 选标准上下文版本。判断是:没人会想主动要更小的上下文窗口

### 替代方案

- **A. 不做白名单,原样透传给 CLI**:保持现状,让 CLI 自己报错。已否决,原因:错值要等打到服务端才炸(慢、且报错信息是英文 API 错误,不友好);而且没有清单,调用方(尤其 AI)根本不知道能传什么,只能猜
- **B. 给 AI 一张「按任务性质选档」的决策表**(机械改动 → low、架构/并发 → xhigh):让 AI 自动选。已否决,原因:模型和思考强度直接决定**成本和耗时**,这是用户的决策不是 AI 的。AI 自动选会让每次调用的开销不可预测;而且"什么算机械改动"判断很容易错。保持"默认走 config,用户明说才换"最可预测
- **C. 续聊回落 config 默认,不沿用首轮**:行为更简单。已否决,原因:首轮指定的模型续聊就丢,同一 session 跨轮换脑子——这是 bug 不是 feature
- **D. claude 白名单同时开放裸 alias 和 `[1m]` 变体**(6 个值):让调用方自己选。已否决,原因:多记 3 个值,且"选裸 alias"这个选项本身就是个陷阱(悄悄降级上下文),没有正当使用场景

---

<a id="adr-008"></a>

## ADR-008 · claude -p 走 stream-json,过程流式输出跟 codex 一致

- **状态**：Accepted
- **决策日期**：2026-06-23
- **最近更新**：2026-06-23
- **标签**：UX / 工具一致性
- **关联代码**：`shell/ai-cli.zsh`（`_ai_parse_claude_stream` 函数 + `_agent_claude_new` / `_agent_claude_c` 调用）
- **关联文档**：`README.md`（流式输出说明）
- **关联决策**：—

### 背景

之前 `agent claude new/c` 用 `claude -p`（默认 text 格式）调 claude，**只输出最终 final message**——`full.log` 跟 `last.txt` 内容一样，看不到 claude 的思考过程、读了哪些文件、调了什么工具。

而 `agent codex new` 用 `codex exec` 是天然流式——`full.log` 能看完整过程。两边体验不一致：
- codex 的 session 文件夹打开 full.log 能复盘整个 agent 推理过程
- claude 的 session 文件夹 full.log 只是 final 拷贝一份，复盘价值极低

实测 claude CLI 支持 `--output-format stream-json --verbose`，每行一条 JSON 事件（thinking / tool_use / tool_result / text / result），等价于 codex 的流式过程——只是需要解析 JSON 转人类可读才能进 full.log。

### 决策

`agent claude new/c` 调用改为：

```bash
claude -p --output-format stream-json --verbose --session-id "$sid" ... \
  | _ai_parse_claude_stream "$sdir/last.txt" \
  | tee -a "$sdir/full.log"
```

`_ai_parse_claude_stream` 用 `jq` 按行解析 stream-json,按 type 分发：

| event type | 转换 |
|---|---|
| `system` / `rate_limit_event` | 跳过(噪音) |
| `assistant.thinking` | `[thinking…]`(内容加密看不到明文) |
| `assistant.tool_use` | `[tool: <name>] <input json>` |
| `user.tool_result` | `[tool_result] <content>`(>500 字截断) |
| `assistant.text` | 直接输出文本 |
| `result` | `[result] <duration>ms \| $<cost>` + 旁路抽 `result.result` 写 `last.txt` |

`jq` 不可用时 fallback 透传原始 JSON 到 full.log(保底不 break),install.sh 检测 jq 缺失时 warn。

### 后果

**正面**
- claude session 跟 codex session 用户体验完全一致——`full.log` 都能复盘完整推理过程
- 流式实时输出(实测每个事件按发生时间逐条出现,sleep 3 秒后才出下一行)
- last.txt 仍然干净(只有 final 文本)
- jq 失败有 fallback,不会因外部依赖问题让 wrapper 完全 break

**负面 / 兼容性**
- 多一个软依赖 `jq`(macOS 需 `brew install jq`);install.sh 已加检测
- claude CLI 升级 stream-json schema 时解析逻辑要跟着更新(维护成本)
- 解析过程中遇到 zsh 一个 quirk：`typeset -g` 全局变量存在时,函数内 `local var` 单独一行 + `var=$(...)` 赋值会泄漏 `var=value` 到 stdout。修复:必须用 `local var=$(...)` 一步声明赋值
- thinking 内容是加密的(带 signature 字段),只能输出占位 `[thinking…]`,不能展示 claude 真实思考内容

### 替代方案

- **A. 保持现状,full.log 跟 last.txt 一样**：放弃跟 codex 体验对齐。已否决，原因：调试 claude 行为时严重缺工具(无法看它读了哪些文件、调了什么工具、思考方向),复盘价值大幅降低
- **B. 用 `--output-format json`（单条 JSON 结果）**：比 text 格式多元信息(cost、duration),但仍**不是流式**——必须等 claude 完全跑完才返回。已否决,原因：流式才是 codex 的核心体验,B 拿不到这个
- **C. 用 Claude Agent SDK 的 ClaudeSDKClient**：原生支持流式 + 中途追加消息。已否决,原因：要重写 wrapper 用 Python/Node,失去 shell 函数的轻量优势

---

<a id="adr-007"></a>

## ADR-007 · 套娃 codex 用 shell `&`,不用 Bash tool `run_in_background:true`

- **状态**：Accepted
- **决策日期**：2026-06-23
- **最近更新**：2026-06-23
- **标签**：套娃 / 进程模型
- **关联代码**：`shell/ai-cli.zsh`（`_ai_claude_nesting_rule` 函数注入到 claude prompt 末尾）
- **关联文档**：`skills/claude-cli/SKILL.md`（"peer 内部起 codex 的姿势——你不用管"段）
- **关联决策**：`implements ADR-006`(硬规则注入的载体)

### 背景

ADR-003 把 claude 重定位为协作 peer，允许它套娃起 codex 干活。peer 起套娃 codex 有两种姿势可选：
- **shell `&`**:`agent codex new ... &`，传统 shell 后台 + fork detach
- **Claude Code Bash tool `run_in_background: true`**:Claude Code 内置的 background process 系统

直觉上两种"看起来"都是后台。但**实测踩坑**：

**测试 1（短任务）**：peer 用 `run_in_background: true` 起 codex 跑 15 秒小任务（sleep 5 + 写文件）→ codex **碰巧赶在 claude 退出前完成**，看起来 OK。

**测试 2（长任务）**：peer 用 `run_in_background: true` 起 codex 跑 90 秒任务（sleep 90 + 写文件）→ peer 11 秒退出 → **codex 启动 8 秒后被连带杀**,产出文件根本没生成,session 的 sid/last.txt 都缺。

**测试 3（shell `&`）**：peer 用 `run_in_background: false` + 命令尾部 `&` 起同一个 90 秒任务 → peer 11 秒退出 → codex 在 init 进程下继续跑了 68 秒 → 产出文件、session 数据全有,完美。

结论：`run_in_background: true` **不是真 detach**——它是 Claude Code 自己维护的 background process pool,peer 进程退出时会主动把里面任务**一起清理掉**。shell `&` 才是真正的 fork + init 收养,孤儿存活。

### 决策

`_ai_claude_nesting_rule` 函数自动注入 claude prompt 末尾(每次 `agent claude new/c` 都加),写明三条硬规则:

1. **禁止** Claude Code Bash tool 用 `run_in_background: true` 起 `agent codex new`
2. **必须**用 `run_in_background: false`(同步 bash) + 命令本身 shell `&` 控制后台
3. 三种典型姿势模板:
   - 单 codex 同步:`agent codex new task "..." -C ...`(不带 `&`,peer 等)
   - 并行 N 个全部等完:`... & ; ... & ; ... & ; wait`(节省时间 = max,不是 sum)
   - 并行不等就退:`... & ; ... &`(不带 wait,用户手动接力)

不打算起套娃就忽略上述,peer 看到无关规则会自动跳过。

### 后果

**正面**
- peer 起套娃 codex 长任务**真的能跑完**,不再被连带杀
- 三种姿势覆盖了所有套娃场景:同步等、并行等、并行不等
- 规则通过 prompt 注入,peer **必然**看到(详见 ADR-006);不依赖 SKILL.md 主动读

**负面 / 兼容性**
- 每次 claude prompt 末尾多一段注入文本(约 600 字),纯方案/分析任务 peer 看到无关规则,占少量上下文空间但 cost 极小
- peer 仍可能错误使用 `run_in_background: true`(模型不是绝对可靠),最终保障靠 ADR-006 + 这条注入的提醒
- shell `&` 起多个 codex 时,peer 用 `wait` 等所有完成期间会"看似没事干",ADR-005 关 watchdog 解决了误杀风险但仍占着 claude session

### 替代方案

- **A. 让套娃 codex 全部同步等**:peer 不用 `&`,串行起多个。已否决,原因：损失并行能力,N 个任务总时间 = sum(t_i) 而不是 max(t_i)。用户场景就是想并行(才有这次讨论)
- **B. wrapper 加 setsid/nohup 强制 detach**:`_agent_codex_new` 内部用 `setsid` 起 codex 脱离父进程组。已否决,原因：macOS 默认没 setsid(GNU coreutils 才有)；nohup 只屏蔽 SIGHUP 不屏蔽 SIGTERM；而且实测 shell `&` 已经能 detach,加 nohup/setsid 是过度防御。**核心问题不在 wrapper 层面而在 peer prompt 层面(用错了 Claude Code background)**,wrapper 改不了 peer 的选择
- **C. 主对话(Claude Code 调度方)在 prompt 里加这条约束,不靠 wrapper 注入**:主对话每次写 peer prompt 时手动写。已否决,原因：主对话可能漏写(尤其复杂任务)；同样的硬规则反复手写出错率高;wrapper 自动注入零成本,保证每次都到位

---

<a id="adr-006"></a>

## ADR-006 · claude 套娃硬规则通过 prompt 注入,不是 SKILL.md 教学

- **状态**：Accepted
- **决策日期**：2026-06-23
- **最近更新**：2026-06-23
- **标签**：提示词注入 / 协作 peer
- **关联代码**：`shell/ai-cli.zsh`（`_ai_claude_nesting_rule` 函数 + 拼接到 `_agent_claude_new` / `_agent_claude_c` 的 prompt 末尾）
- **关联文档**：`skills/claude-cli/SKILL.md`(删掉"peer 起套娃 codex 的硬规则"大段)
- **关联决策**：`implemented by ADR-007`(具体规则内容)

### 背景

ADR-007 拍板"peer 套娃 codex 必须用 shell `&`,不用 `run_in_background: true`"。这条硬规则要传达给 peer——但传哪儿合适?

候选载体:
- **`skills/claude-cli/SKILL.md`**:Claude Code 的 skill 文档,peer 启动时**可能**读到
- **prompt 注入**:wrapper 自动在 peer 的 prompt 末尾追加,peer **必然**读到

实际差异在「peer 是否会主动读 claude-cli/SKILL.md」。SKILL.md 触发机制:Claude Code 在系统提示词里看到 skill 描述,只有遇到"需要起外部 claude"才触发读 SKILL 全文。peer **作为被起的方**,启动时它的角色不是"起外部 claude"——它是 peer 自己。所以 peer 不一定会主动读 claude-cli/SKILL.md。

但 peer **一定**会读到 prompt 末尾——因为那是它的上下文必然部分。

### 决策

套娃硬规则放在 **wrapper 自动注入的 prompt 末尾**,跟 codex 的 safety suffix(`_ai_safety_suffix`)形态对称:

| | codex | claude |
|---|---|---|
| safety suffix | 自动注入"不要 git commit"+"不要套娃 agent" | **不注入** safety,但**注入套娃硬规则** |
| 含义 | 工具型,加约束防误用 | 协作 peer,完整能力放开;只补充"如果要套娃,必须这么起" |

具体实现:`_ai_claude_nesting_rule` 函数返回硬规则文本,`_agent_claude_new` 和 `_agent_claude_c` 拼接到 `$prompt` 末尾后传给 claude。

同时,从 `skills/claude-cli/SKILL.md` **删掉** "peer 起套娃 codex 的硬规则" 大段——主对话不需要知道(wrapper 帮 peer 兜底)。

### 后果

**正面**
- peer **必然**收到硬规则,不依赖 skill 触发或主动读 SKILL
- 主对话(Claude Code)调用 peer 的逻辑简化——不用在 prompt 里手动写套娃规则,wrapper 兜底
- SKILL.md 更精简,主对话视角更清晰(只关心"我怎么起 peer",不操心"peer 内部怎么干活")

**负面 / 兼容性**
- 每次 claude prompt 都注入约 600 字硬规则文本,纯方案/分析任务略冗余;但 token cost 极小
- 注入文本要长期维护——claude CLI 行为变了或 ADR-007 演进,这段也要跟
- 跟 codex 的 safety suffix 对称结构:都是"自动尾部追加",但内容性质不同(codex 是禁令,claude 是实操指南)。这种"形态对称内容不同"可能让新读者困惑——靠注释 + ADR 这条说清楚

### 替代方案

- **A. 写进 SKILL.md 让 peer 自己读**:即原始做法。已否决,原因：peer 不一定主动读(peer 不是"调用 claude-cli skill 的人",而是被起的方);peer 看不到 SKILL = 套娃姿势用错 = 长任务 codex 被杀
- **B. 主对话在 prompt 里手动加套娃规则**:Claude Code 主对话每次起 peer 时手写这段约束。已否决,原因：主对话可能漏(尤其专注业务任务时);同样规则反复手写出错率高;wrapper 注入零成本保证到位
- **C. 改 claude CLI 的系统提示词**(让所有 claude 实例都知道):不可行,我们没法改 claude CLI 内部的 system prompt;只能在 user prompt 注入

---

<a id="adr-005"></a>

## ADR-005 · 关闭 claude wrapper 的 watchdog

- **状态**：Accepted
- **决策日期**：2026-06-23
- **最近更新**：2026-06-23
- **标签**：协作 peer / 资源管理
- **关联代码**：`shell/ai-cli.zsh`(`_agent_claude_new` / `_agent_claude_c` 删除 `_ai_watchdog` 调用 + 清理)
- **关联文档**：`skills/claude-cli/SKILL.md`("peer 内部起 codex 的姿势"段提到此事)
- **关联决策**：`refines ADR-003`(协作 peer 定位的进一步落地)

### 背景

`agent codex new` 和 `agent claude new` 都自带 watchdog:监控 `full.log` mtime,5 分钟无更新 → 自动 kill + 抓诊断包。这套保护对**工具型** session 有意义(codex 卡死要及时止损)。

但 claude 重定位为协作 peer 后(ADR-003),它的行为模式变了:
- peer 起 `agent codex new ... & ... & wait`,wait 多个并行 codex 可能跑 10 分钟以上
- wait 期间 peer 自己没新 stream-json 事件输出,`full.log` mtime 不更新
- 5 分钟阈值触发 → watchdog 杀 peer + 它所有套娃 codex 全废

ADR-007 推荐 shell `&` 起多个 codex 走 `wait` 等齐,正好踩到这个 watchdog 误杀。

### 决策

`agent claude new/c` 完全**不起 watchdog**:
- `_agent_claude_new` 和 `_agent_claude_c` 删除 `_ai_watchdog` 调用 + 相关清理代码(约 40 行)
- 简化为只 polling 等待 `pipeline_pid` 结束
- `_ai_watchdog` 函数本身保留(codex 仍在用)
- 真正卡死场景靠用户 Ctrl-C 兜底

codex 的 watchdog **不动**——codex 是工具型,需要这层保护。

### 后果

**正面**
- peer wait 多个并行 codex 不再触发误杀
- 套娃工作流可以跑很久(>10 分钟)不被打断
- 实现简单——删代码而不是加复杂逻辑(对比方案 B "智能 watchdog")

**负面 / 兼容性**
- claude 真正卡死(API hang / 网络断)不会被自动杀,要用户 Ctrl-C
- 失去诊断包收集——claude 卡死时不会自动抓 stack/lsof/env 诊断信息
- 用户主动 kill 时仍会连带杀套娃 codex(同步起的话)。这是符合预期的——要停就停整个工作流

### 替代方案

- **A. 智能 watchdog(检测"在等子进程")**:`_ai_watchdog` 扫 claude 进程的后代,有活跃 codex/agent 子进程就不算 stale。已否决,原因：实测发现 peer 用 shell `&` 起 codex 后,codex wrapper 被 init 收养(孤儿),不在 claude 进程树里,扫不到——智能判断会误判为 stale 然后仍然杀
- **B. 调高 watchdog 阈值**:`AI_WATCHDOG_KILL_CHECKS=30`(15 分钟)。已否决,原因：阈值难拍——15 分钟够吗?套娃 20 分钟也合理;再调高等于实际关掉,何必绕弯
- **C. 加 flag `--allow-nesting` 显式禁 watchdog**:Claude Code 调 peer 时显式传。已否决,原因：增加 Claude Code 调用方的认知负担;主对话每次调 peer 都要判断"会不会套娃"——往往判断不准

---

<a id="adr-004"></a>

## ADR-004 · claude=前端开发优先,codex=后端开发优先

- **状态**：Accepted
- **决策日期**：2026-06-23
- **最近更新**：2026-06-23
- **标签**：工具分工
- **关联代码**：—(纯文档约定)
- **关联文档**：`skills/claude-cli/SKILL.md` + `skills/codex-cli/SKILL.md` 双向标注
- **关联决策**：`refines ADR-003`(协作 peer / 工具 定位的实际派任务规则)

### 背景

ADR-003 定了 claude=协作 peer / codex=工具 的角色定位。但具体派任务时,什么任务派 claude、什么派 codex?除了"出方案 vs 干活"的粗分,实践中发现**领域**也是关键差异:

- claude(Anthropic Opus)在**前端**领域(React/Vue/CSS/UI 框架/前端工程化/TypeScript 前端类型)的判断和实现力比 codex(gpt-5.5)更顺手——UI 直觉、组件抽象、CSS 调优都更稳
- codex(gpt-5.5 xhigh 模式)在**后端/系统编程**(Go/Rust/Java 服务、数据库 schema/migration、并发/分布式、性能优化)更擅长——系统级编程、强类型语言、底层优化是它的长项

如果不加区分,Claude Code 倾向于无脑把开发任务都派 codex,前端任务结果次优。

### 决策

两份 SKILL.md 同步加「开发领域分工」三列表(领域 / 优先 / 理由),给出反例:

| 领域 | 优先 |
|---|---|
| 前端(React/Vue/CSS/UI 框架/前端工程化) | **claude** |
| 后端(Go/Rust/Java/数据库/分布式/系统编程) | **codex** |
| 全栈/纯逻辑(算法/脚本/工具函数) | 默认 codex |

frontmatter description 也同步:
- claude-cli 触发词加"用 claude 写前端"
- codex-cli 触发词加"codex 写后端" + 明确"前端开发优先 claude-cli"

反例提示:"用户说'帮我加个 React 组件'直接派 codex 是次优——改派 claude-cli"。

### 后果

**正面**
- Claude Code 派任务时能按领域选对工具,前端任务质量提升
- 两份 SKILL 双向标注,无论从哪个 skill 触发都能看到分工

**负面 / 兼容性**
- 「前端 vs 后端」分工是经验性的,不绝对——某些前端 SDK / 库的复杂逻辑 codex 也可能更好,某些后端 DSL claude 也可能更顺。SKILL.md 标"优先"不"必须",留判断空间
- 模型版本升级可能反转分工(比如 gpt-5.6 前端突飞猛进)。届时需要重新评估并更新 ADR

### 替代方案

- **A. 不分领域,只按 ADR-003 角色定位派任务**:出方案 → claude / 干活 → codex。已否决,原因：实践中 Claude Code 倾向无差别派 codex,前端任务结果次优;明确分工能纠偏
- **B. 写更细的分工矩阵(按具体框架 / 语言)**:React → claude, Vue → claude, Go → codex, Python → ?(标量哪边)…已否决,原因：维护成本高,框架/语言增长快;粗分"前端 vs 后端"已经能覆盖 80% 场景

---

<a id="adr-003"></a>

## ADR-003 · claude=协作 peer,codex=工具(差异化定位 + safety suffix 差异)

- **状态**：Accepted
- **决策日期**：2026-06-22
- **最近更新**：2026-06-23
- **标签**：角色定位 / 安全约束
- **关联代码**：`shell/ai-cli.zsh`(`_agent_claude_new` 不追加 `_ai_safety_suffix`;`_agent_codex_new` 仍追加)
- **关联文档**：`skills/claude-cli/SKILL.md`(协作 peer 定位 + 不追加 safety 说明) + `skills/codex-cli/SKILL.md`(工具定位 + 仍追加 safety)
- **关联决策**：`refined by ADR-004`(领域分工) / `refined by ADR-005`(关 watchdog) / `refined by ADR-006/007`(套娃硬规则)

### 背景

最初设计 `ai-codex` 和 `ai-claude` 时,两者基本对称——都自动追加 safety suffix("不要 git commit"+"不要套娃 agent"),都起 watchdog,都按工具型 session 用。

但实际用下来发现两边的角色性质不一样:

- **codex**:被调工具型,默认 `danger-full-access`(改文件 / 跑命令风险高);调用方需要给约束防误用;session 短(几十秒到几分钟);适合开发/实现/重构任务
- **claude**:协作伙伴型,跟 Claude Code 共享同一套系统提示词和 CLAUDE.md(信任度对等);需要完整能力做协作(出方案、跨项目读、追踪进度、必要时改文件);session 可能很长(出方案、多轮讨论、跨项目协调)

把 claude 当工具用反而限制了它的协作能力,而且 safety suffix 自动加"不要 git commit"对协作场景过度——peer 出方案过程中如果用户授权,提交也是合理操作。

### 决策

**差异化定位**:

| | claude | codex |
|---|---|---|
| 角色 | 协作 peer(同 Claude Code 平级) | 被调工具 |
| 与 Claude Code 信任度 | 一致(共享 prompt + CLAUDE.md) | 较低(不同模型不同 prompt) |
| safety suffix | **不追加** | 仍追加"不要 git commit"+"不要套娃 agent" |
| 默认能力 | 完整放开(改文件 / 跨项目读 / 起 codex 套娃 / 自主推进) | 工具型约束 |
| 适合任务 | 出方案 / 跨项目协调 / 独立工作流接管 / 追踪进度 / 套娃调度 codex | 改代码 / 重构 / 加测试 / 修 bug |

实现:
- `_agent_claude_new` 和 `_agent_claude_c` 的 prompt **不追加 `_ai_safety_suffix`**(原样透传 `$prompt`)
- `_agent_codex_new` 和 `_agent_codex_c` 仍追加(行为不变)
- SKILL.md 重写 claude-cli 为"协作 peer"定位,codex-cli 为"工具"定位

约束如果协作任务需要(比如"只分析不改文件"),让用户/Claude Code 主对话写进 prompt——不再自动加。

### 后果

**正面**
- claude 能做完整协作:跨项目读、出双边方案、追踪进度、改基础文件(deploy.yaml / 配置 / 文档)、起 codex 套娃干大开发
- Claude Code 跟 peer 的关系自然——同事而不是上下级
- codex 仍受 safety 保护,工具型任务该有的约束都有

**负面 / 兼容性**
- 用户/主对话**必须**自己写约束(比如"不要改文件"),忘了 claude 真的会改。SKILL.md 给了几个常用约束模板缓解
- 协作 peer 的"完整能力"包括起 codex 套娃,引出 ADR-005 / 006 / 007 的连锁问题(watchdog 误杀 / 套娃硬规则 / shell `&` 选择)
- 后续被多条 ADR refine(005/006/007)——单条 ADR 不足以解决协作 peer 的所有衍生问题

### 替代方案

- **A. 保持对称,两边都自动加 safety**:简单一致。已否决,原因：限制了 claude 的协作能力;safety 对 codex 必要(工具型默认 danger-full-access),对 claude 过度
- **B. 让用户每次显式传 `--safety` flag 决定加不加**:灵活但繁琐。已否决,原因：增加调用方认知负担;用户记不住要传;默认值难拍(默认加 vs 默认不加)
- **C. 给 claude 加"弱化版" safety**(只禁 git push,允许 commit):中间地带。已否决,原因：边界模糊,什么算"弱化"难说;协作 peer 信任度高,要不就完全放开,要不就跟 codex 一样;弱化版增加复杂度

---

<a id="adr-002"></a>

## ADR-002 · 移除顶层 `agent()` shell 函数,wrapper 是唯一入口

- **状态**：Accepted
- **决策日期**：2026-06-22
- **最近更新**：2026-06-22
- **标签**：函数管理 / shell snapshot
- **关联代码**：`shell/ai-cli.zsh`(末尾删 `agent() { _agent_dispatch "$@"; }` 一行)
- **关联文档**：`shell/ai-cli.zsh` 末尾注释说明
- **关联决策**：`refines ADR-001`(`agent` 统一入口的实施细节)

### 背景

ADR-001 引入 `agent` 命令时,为了交互终端方便,在 `shell/ai-cli.zsh` 末尾定义了一个顶层函数:

```zsh
agent() { _agent_dispatch "$@"; }
```

同时 `bin/agent` wrapper 也已经在 `~/.local/bin/agent`(给非交互 shell 用)。zsh 函数优先级 > PATH 文件,交互终端会优先用函数。

但在 **Claude Code Bash tool 环境**踩到了 shell snapshot 缓存问题:

```
agent ls 2>&1 | head -3
→ agent:1: command not found: _agent_dispatch
```

排查发现 Claude Code Bash tool 启动 zsh 时不读完整 zshrc,而是 source 一个 shell snapshot 文件(`~/.claude/shell-snapshots/snapshot-zsh-*.sh`)加速启动。snapshot 抓取时**只快照公开函数(`agent`)**,**不抓内部下划线前缀函数(`_agent_dispatch`)**。结果:`agent()` 函数体调 `_agent_dispatch` → 找不到 → 报错。

snapshot 是某个时间点的状态冻结,后续 ai-cli.zsh 改动不会自动同步到 snapshot;每次想看新版要么重启 Claude Code 重抓 snapshot,要么清掉 snapshot。这种状态不一致根本上难修。

### 决策

**移除 `agent()` 顶层函数**,改成纯注释说明。`agent` 命令统一走 `~/.local/bin/agent` wrapper:

```zsh
# 注:不在这里定义顶层 agent() 函数。
# agent 命令统一走 ~/.local/bin/agent wrapper。让 wrapper 是唯一入口,避免 shell snapshot
# 缓存只抓部分函数(比如 agent 有、_agent_dispatch 没)导致命令崩。
```

wrapper 内部 `source ai-cli.zsh` 加载所有内部 `_agent_*` 函数,**完全独立于 shell 状态/snapshot**。

### 后果

**正面**
- 跨 shell 状态、snapshot/无 snapshot 环境行为一致,不再踩 shell-snapshot 缓存 bug
- 实现极简——删一行函数定义,加一段注释
- 用户行为透明:`agent ls` 还是 `agent ls`,只是底层不再依赖"shell 已 source ai-cli.zsh"假设

**负面 / 兼容性**
- 交互终端每次跑 `agent` 多一次 source 开销(`bin/agent` 进程启动 + source 文件),但毫秒级,完全可忽略
- 失去了"shell 函数优先"的某些细微好处(比如交互终端 history 集成),但 wrapper 体验已经够好

### 替代方案

- **A. 保留 `agent()` 函数,定期清 shell snapshot**:`rm ~/.claude/shell-snapshots/*` 让 Claude Code 重抓。已否决,原因：snapshot 之后还会再变旧,这是系统性问题不是一次性 bug;定期清是用户额外负担
- **B. 把所有内部 `_agent_*` 函数也定义成顶层(非下划线前缀)让 snapshot 抓到**:不仅 `agent()`,所有 `_agent_dispatch` 等都改名。已否决,原因：污染命名空间(几十个函数);破坏内部/外部边界约定
- **C. 改 Claude Code snapshot 抓取规则让它抓内部函数**:我们没法改 Claude Code,该方案不可行

---

<a id="adr-001"></a>

## ADR-001 · 统一入口 `agent` 命令,移除 8 个 `ai-*` 老命令

- **状态**：Accepted
- **决策日期**：2026-06-22
- **最近更新**：2026-06-22
- **标签**：CLI 入口 / UX
- **关联代码**：`bin/agent`(wrapper 单文件) + `shell/ai-cli.zsh`(`_agent_dispatch` 路由 + 内部 `_agent_*` 实现函数)
- **关联文档**：`README.md`(命令清单 + 子命令)
- **关联决策**：`refined by ADR-002`(移除顶层 `agent()` 函数)

### 背景

项目最初设计有 8 个独立 `ai-*` 命令:

```
ai-codex / ai-codex-c / ai-claude / ai-claude-c
ai-sessions / ai-rm / ai-incidents / ai-update
```

每个命令一个 wrapper 文件(`~/.local/bin/ai-codex` 等),用户要记 8 个命令名。问题:

- 命令多了认知负担大,新人上手要看完整清单才知道有什么
- 同类操作分散(`ai-codex` 和 `ai-codex-c` 是新建 vs 续聊;`ai-sessions` 和 `ai-rm` 都是 session 管理)
- 缺少层次感——所有命令并列,没有"动作 → 子动作"的结构

参考 git / kubectl / docker 这类成熟 CLI 的设计:**单一入口 + 子命令树**(`git add`, `git commit`, `git push` 都从 `git` 进去)。

### 决策

**统一入口 `agent` + 子命令**:

```
agent codex new <name> <desc> <prompt> [flags]
agent codex c   <name> <prompt> [flags]
agent claude new <name> <desc> <prompt> [flags]
agent claude c   <name> <prompt> [flags]
agent ls [codex|claude]
agent rm <name>
agent incidents [<id>]
agent update
agent help / agent codex help / agent claude help
```

实现:
- `bin/agent` 单一 wrapper(~/.local/bin/agent)
- `_agent_dispatch` 函数负责路由(`agent codex new ...` → `_agent_codex_new`)
- 8 个内部函数(`_agent_codex_new` 等)是实际实现

老 `ai-*` 命令完全移除,**不保留 alias 兼容期**——一刀切。

### 后果

**正面**
- 命令结构清晰:`agent <对象> <动作>` 跟 `kubectl get pods` 同一套思路
- 用户只需记一个入口 `agent`,子命令通过 `agent help` 探索
- 新增功能时不再污染 PATH(原本一加新命令就要铺一个 wrapper 文件)
- 子级 help(`agent codex help` / `agent claude help`)给更细的用法

**负面 / 兼容性**
- **没有 alias 兼容期**——老用户必须立刻迁移,直接 `command not found: ai-codex`。激进决策,符合"小项目 + 个人用 + 频繁迭代"的特征
- 命令稍长(`agent codex new x` 比 `ai-codex x` 多几个字符)——但子命令树结构带来的可读性收益大于这点输入成本
- ADR-002 接续踩了 shell-snapshot 的坑(顶层 `agent()` 函数被部分快照)——单独处理

### 替代方案

- **A. 保留 8 个 `ai-*` 命令不变**:不重构。已否决,原因：长期来看命令数还会增加(可能加 gemini / qwen 等),早晚要做统一入口
- **B. 统一入口但保留 6 个月 alias 兼容期**:`ai-codex` 仍可用但打 deprecation 警告。已否决,原因：小项目个人用,迁移成本极低(改自己的肌肉记忆 + 几条脚本);兼容期增加 wrapper 文件维护成本,得不偿失
- **C. 不用单一入口,改用 `codex` / `claude` 两个顶层命令**(去 `ai-` 前缀):`codex new`、`claude session list` 等。已否决,原因：`codex` 和 `claude` 本身就是 CLI 名字(OpenAI / Anthropic 的官方 CLI),用同名会撞;`agent` 不撞且语义清晰

---

## 明确已删除（防回流）

> 集中列出已删除的接口 / 字段 / 命令,标明「不应再写进新代码或新文档」。

- **`~/.local/bin/ai-codex` / `ai-codex-c` / `ai-claude` / `ai-claude-c` / `ai-sessions` / `ai-rm` / `ai-incidents` / `ai-update`** (2026-06-22 删除,ADR-001)——8 个老命令 wrapper 完全移除,不保留 alias 兼容期。新文档 / 新脚本一律用 `agent <subcommand>` 形式
- **`~/.local/bin/ai-cli-wrapper`** (2026-06-22 删除)——老 wrapper 的薄壳依赖,跟 8 个 `ai-*` 命令一起删
- **顶层 `agent() { _agent_dispatch "$@"; }` shell 函数**(2026-06-22 删除,ADR-002)——避免 shell snapshot 缓存部分函数导致命令崩。当前 `shell/ai-cli.zsh` 末尾只有注释说明,**不要再加回来**
- **claude 的 safety suffix 注入**(2026-06-23 删除,ADR-003)——claude 当协作 peer 用,完整能力放开。`_ai_safety_suffix` 仍存在但只对 codex 用,不要再给 claude 加
- **claude wrapper 的 watchdog**(2026-06-23 删除,ADR-005)——协作 peer 等多个并行 codex 时 5 分钟阈值会误杀。`_ai_watchdog` 仍存在但只对 codex 用,不要给 claude 调回
- **`skills/claude-cli/SKILL.md` 的「peer 起套娃 codex 的硬规则」段**(2026-06-23 删除,ADR-006)——主对话不需要管 peer 内部姿势,规则改成 `_ai_claude_nesting_rule` 自动注入 prompt 末尾。SKILL.md 不要再写一遍硬规则细节

---

## 记录规范

- **领新编号**:索引表找最大编号 +1,编号一旦分配不复用(即使 Rejected 也占位)
- **状态枚举**:Accepted / Deprecated / Superseded / Rejected。废弃或被替代的**不删**,只改状态
- **结论被否 ≠ 原地改正文**:起一条新 ADR,旧条标 Superseded,新条「关联决策」写 `supersedes ADR-xxx`,旧条「关联决策」回写 `superseded by ADR-xxx`。决策可演进,记录不重写
- **关系动词**(关联决策字段用,按强度递减):
  - `supersedes / superseded by ADR-xxx`:直接推翻 / 被推翻;旧条状态必须改 Superseded
  - `refines ADR-xxx`:在不推翻结论的前提下细化、增加约束
  - `updates ADR-xxx`:补丁式修订(小范围调整),旧条仍 Accepted
  - `implements ADR-xxx`:落地某条更上位的决策
  - `follows ADR-xxx`:在某条决策之后必然要做的接续动作
  - `related ADR-xxx`:相关但无强依赖,仅供阅读时交叉参考
- **复盘块**:决策上线后被现实打脸 / 发现同类型 bug 复发 / 假设证伪 → 在原 ADR 正文最上方加 `> **YYYY-MM-DD 后续:…**` quote 块,写清教训。**不改原决策结论**,让历史留痕
- **存量处置**:决策落地涉及历史数据迁移 / 回填 / 备份时,在正文末尾加「存量处置」段,写明 SQL 备份位置、回填脚本路径、是否可幂等重跑
