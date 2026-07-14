# ai-cli-skills

用 shell 函数 + Claude Code skill 把 **codex CLI** 和 **claude CLI** 的非交互调用包装成「**多 session 并行 + 按 name 续聊 + worktree 隔离开发**」的工作流。

让 Claude Code 调外部 AI 干活时,能像调内部工具一样自然——给个 name 起 session,改完文件 commit 在 worktree,审完 merge 回主分支。

## 安装 / 更新 / 卸载

**初次安装**:
```bash
curl -fsSL https://raw.githubusercontent.com/AmorErwanc/ai-cli-skills/main/install.sh | bash
```

想审脚本再装(推荐):
```bash
curl -O https://raw.githubusercontent.com/AmorErwanc/ai-cli-skills/main/install.sh
less install.sh
bash install.sh
```

装完**重启终端**,跑 `agent ls` 验证。

**已装用户更新到最新版**(等同重跑 install.sh,但命令短):
```bash
agent update
```

**卸载**:
```bash
curl -fsSL https://raw.githubusercontent.com/AmorErwanc/ai-cli-skills/main/uninstall.sh | bash
```

### 依赖

- `zsh`(macOS 默认就是)
- `git`、`curl`、`uuidgen`(macOS 都自带)
- `codex` CLI:https://github.com/openai/codex
- `claude` CLI:https://docs.claude.com/en/docs/claude-code

codex/claude 没装也能装本工具,只是不能跑——装完任何一个就能用对应那一半。

## 用法速览

统一入口 `agent`,一个命令收拢所有操作:

### 子命令

| 子命令 | 作用 |
|---|---|
| `agent codex  new <name> <desc> (<prompt>\|-f file) [flags]` | 新起 codex session |
| `agent codex  c   <name> (<prompt>\|-f file) [flags]` | 续聊 codex session |
| `agent claude new <name> <desc> (<prompt>\|-f file) [flags]` | 新起 claude session |
| `agent claude c   <name> (<prompt>\|-f file) [flags]` | 续聊 claude session |
| `agent ls [codex\|claude]` | 列 session(可按 cli 过滤,无过滤时按 cli 分组) |
| `agent rm <name>` | 删除某 session(短名歧义时用完整 `codex-<name>` / `claude-<name>`) |
| `agent incidents [<id>]` | 列出 / 查看 watchdog 抓的 hang 诊断包(详见下文 Watchdog) |
| `agent update` | 一键更新到最新版(等同重跑 install.sh) |
| `agent help` / `agent codex help` / `agent claude help` | 顶层用法 / 子命令详细用法 |

### 参数

- `<name>`:kebab-case,语义化(`audit-payment`、`refactor-auth`)
- `<desc>`:`new` 必填,**≥ 15 字符**,讲清这个 session 在做什么
- `<prompt>`:位置参数 prompt 字符串,适合短任务。**以 `-` 开头会被当 flag**,这种情况改走 `-f`
- `-f <file>`:从文件读 prompt,**跟 `<prompt>` 互斥**。以下任一情况推荐 `-f`:
  - prompt 含反引号 `` ` ``、`$`、`&` 等会被 shell 解析的特殊字符
  - prompt 以 `-` 开头
  - prompt 很长(几行以上)

  文件内容会自动 archive 到 `<session>/prompt.md`(new)或 `prompt-round-N.md`(续聊),方便复盘。

可选 flag(默认不传,走 config):
- `-m <model>` 指定模型
- `-e <level>` 指定思考强度
- `-C, --cwd <dir>` 工作目录(等价于先 `cd <dir>` 再起,**不传 = 当前 shell PWD**)

### 模型 / 思考强度(`-m` / `-e`)

**默认不传就对了**——不传 = 走本机 `~/.codex/config.toml` / `~/.claude/settings.json`。只有明确想换档时才传。

| | `-m` 可选模型 | `-e` 可选思考强度 |
|---|---|---|
| **codex** | `gpt-5.6-sol`、`gpt-5.6-luna` | `low` `medium` `high` `xhigh` `max` |
| **claude** | `opus`、`sonnet`、`fable` | `low` `medium` `high` `xhigh` `max` |

三条规则:

- **白名单外的值直接报错**,不透传给 CLI。两个 CLI 认识的取值其实远不止这些(codex 还吃 `none`/`minimal`/`ultra` 和十几个 gpt-5.x 模型),但档位铺太开只会让人选错——想用别的值请直接改本机 config。
- **claude 的三个模型都自动解析成 1M 长上下文变体**(`opus` → `opus[1m]`)。裸 alias 拿到的是标准上下文窗口,而本机默认配的就是 `opus[1m]`;不做这层映射的话,"显式指定 opus" 反而会把上下文从 1M 悄悄缩回标准档,是纯粹的能力降级。
- **new 时传了会记进 session,续聊自动沿用**同一档,不会中途换脑子。续聊显式传则覆盖,并成为之后各轮的新默认。

```bash
# 默认(推荐):不传,走本机 config
agent codex new fix-auth "修登录态失效的边界问题" "<prompt>"

# 换档:显式指定
agent codex new audit-pay "审计支付并发安全" "<prompt>" -m gpt-5.6-luna -e xhigh
agent claude new eval-x "评估缓存选型" "<prompt>" -m sonnet -e high

# 续聊自动沿用 luna + xhigh,不用重复传
agent codex c audit-pay "刚才漏了退款路径,补一下"
```

### 协作关系(claude 是 peer,codex 是工具)

这套工具的核心分层:

```
用户
 │
 ▼
Claude Code  (主对话,调度方)
 │
 ├──► agent claude new   →  外部 claude (协作 peer)
 │                              ├─ 出方案、跨项目读、追踪进度
 │                              └─ 自己也能起 agent codex new 让 codex 干活 ✓ 允许
 │
 └──► agent codex new   →  codex (被调工具)
                              └─ 改文件、跑命令,干完就完
                                 不会再起新 agent session ✗ 禁套娃
```

**claude 当协作者**:能扛一段独立工作流(比如"A 项目改完表结构需要 B 项目跟改代码",claude 直接读 B、出双边方案、追踪两边进度)。它自己**不写代码**,落地实现的部分自己起 codex 子任务干。

**codex 当工具**:只负责"动手改代码"。无论是 Claude Code 直接起,还是外部 claude 起,codex 都不会再起新 agent session——所以最多 claude → codex 两层,不会无限套娃。

### Safety suffix(仅 codex,claude 不加)

**只有 `agent codex new/c`** 在 prompt 末尾自动追加两条约束:

> 1. 不要执行 git commit 或 git push。
> 2. 不要调用 agent 命令起新 session,避免任务套娃。

`agent claude new/c` 把 prompt **原样透传**,不追加任何东西——把 claude 当协作者用,完整能力交给它(包括 commit / push / 起 codex 子任务),需要的约束自己写进 prompt。codex 因为是被调工具(默认 `danger-full-access`),保留 safety suffix 防止它误改 git 历史或起新 session 形成套娃嵌套。

### 一个例子(短 prompt + 长 prompt 两种)

```bash
# 短任务:位置参数 prompt
agent codex new add-cache "给 auth 模块加 Redis 缓存避免重复查 DB" \
  "[目标] 给 src/auth/get-user.ts 加 Redis 缓存。[约束] 不要装新依赖。[产出] 改完一句话说改了啥。" \
  -C ~/project/myapp

# 复杂 prompt(多行、含特殊字符):走 -f 文件
cat > ~/tmp/agent-prompt-foo.md <<'EOF'
[目标] 评估 redis vs memcached 在缓存层的取舍
[背景] 我们的系统 $TPS 大约 5000,有 markdown 代码块的反引号 `code` 都安全
EOF
agent claude new eval-cache "评估缓存方案选型(redis vs memcached)" \
  -f ~/tmp/agent-prompt-foo.md -C ~/project/myapp

# 续聊
agent codex c add-cache "刚才加的缓存没处理 cache miss 时的 thundering herd,加个 SETNX 锁。"

# 按 cli 看 session
agent ls            # 分组显示 [codex] 和 [claude]
agent ls codex      # 只看 codex

# 删
agent rm add-cache
```

## Session 数据存哪

```
<主项目根>/.ai-sessions/<cli>-<name>/
  sid          # session UUID
  desc         # 描述
  model        # 起 session 时指定的模型(没指定就没这个文件 = 走 config)
  effort       # 起 session 时指定的思考强度(同上)
  last.txt     # 最新一轮的最终回答(覆盖式)
  full.log     # 完整流式输出累加(看过程、工具调用)
```

`model` / `effort` 是续聊沿用的依据——没有这两个文件就说明该 session 一直走本机 config 默认。

**永远落在主项目根**——通过 `git rev-parse --git-common-dir` 定位,worktree 里跑也回到主项目,worktree 删除不丢 session。

`.ai-sessions/` 自带 `.gitignore`(内容 `*`),不会被 commit。

## Watchdog:防 codex/claude 卡死

外部 CLI(尤其 codex)在并发或长 prompt 下偶发会卡死(CPU 0、stdout 没输出)。wrapper 自带 watchdog:

- **120s 无新输出 → 警告**:终端铃 + macOS notification
- **5 分钟无新输出 → 自动 kill + 抓诊断包**

诊断包存在 `~/.ai-sessions-incidents/<时间戳>-<cli>-<name>/`,包含:

| 文件 | 内容 |
|---|---|
| `summary.md` | 时间、CLI、name、原因、PID、session 路径 |
| `stack.sample.txt` | macOS `sample` 抓的进程调用栈(看卡在哪个 syscall) |
| `lsof.txt` / `lsof-net.txt` | 打开的 fd / 网络连接 |
| `process.txt` | CPU TIME、wchan、状态 |
| `concurrent.txt` | 当时活跃的其他 codex/claude 进程(查 race) |
| `env.txt` | codex/claude/node 版本、macOS 版本、内存 |
| `prompt-info.txt` | 卡死时的 prompt 长度 + 前 800 字符 |
| `full.log.snapshot` | 卡死时 log 完整快照 |

**查看 / 管理 incidents**:

```bash
agent incidents                  # 列出全部
agent incidents <id 关键字>      # 看详情
rm -rf ~/.ai-sessions-incidents/<id>   # 清理某个
```

**调整阈值**(环境变量,默认值合理大多场景不用动):
```bash
export AI_WATCHDOG_INTERVAL=30      # 检查间隔(秒)
export AI_WATCHDOG_WARN_CHECKS=4    # 多少次无更新 → warn
export AI_WATCHDOG_KILL_CHECKS=10   # 多少次无更新 → kill
```

## 文件分工

| 文件 | 干嘛 |
|---|---|
| `shell/ai-cli.zsh` | shell 函数实现(`agent` dispatcher + 4 个核心命令 + 4 个管理命令) |
| `bin/agent` | 单一入口 wrapper,装到 `~/.local/bin/agent`,让非交互 shell(Claude Code Bash tool / cron / systemd)也能直接用 |
| `skills/codex-cli/SKILL.md` | 教 Claude Code 怎么调 codex CLI(开发型任务、worktree 流程、任务调度) |
| `skills/claude-cli/SKILL.md` | 教 Claude Code 怎么调 claude CLI(协作 peer 定位、跨项目协调、套娃姿势) |
| `docs/decisions.md` | 架构决策记录(ADR)——为什么 claude/codex 这么定位、为什么关 watchdog、为什么 shell `&` 不用 `run_in_background` 等关键设计原因 |
| `install.sh` / `uninstall.sh` | 一键安装/卸载(自动建 `~/.local/bin`、铺 wrapper、检测 PATH) |

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/AmorErwanc/ai-cli-skills/main/uninstall.sh | bash
```

只清安装的文件 + zshrc 里的 source 行;项目里的 `.ai-sessions/` 数据**保留**,需要清理自行 `rm -rf`。

## 设计要点

- **默认零配置**:model / effort / 权限全走用户已有的 `~/.codex/config.toml` 和 `~/.claude/settings.json`;`-m` / `-e` 只在明确要换档时才传,且只开放收窄过的白名单
- **session 集中管理**:主项目根的 `.ai-sessions/`,跨 worktree 共享
- **name 撞车立即报错**:绝不静默接错 session(防止旧上下文污染新任务)
- **必带 desc**:≥ 15 字,半年后回来还看得懂自己起的 session 在干啥
- **safety 约束自动注入**:每条 prompt 末尾加"不要 git commit/push",防 AI 乱提交
- **Claude Code skill 集成**:让 agent 学一遍就会用,不用手把手教

详细规则见 `skills/codex-cli/SKILL.md` 和 `skills/claude-cli/SKILL.md`。

## License

MIT
