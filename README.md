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
- `-m <model>` 覆盖模型
- `-e <level>` 覆盖思考强度(`low/medium/high/xhigh/max`)
- `-C, --cwd <dir>` 工作目录(等价于先 `cd <dir>` 再起,**不传 = 当前 shell PWD**)

### Safety suffix(每条 prompt 自动追加)

shell 函数在每条 prompt 末尾追加两条约束:

> 1. 不要执行 git commit 或 git push。
> 2. 不要调用 agent 命令起新 session,避免任务套娃。

第 2 条防 codex/claude 在 `danger-full-access` / `bypassPermissions` 模式下主动起新 session 形成嵌套。Claude Code 当外层调度方,被起的 codex/claude 当执行方,不再嵌套。

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
  last.txt     # 最新一轮的最终回答(覆盖式)
  full.log     # 完整流式输出累加(看过程、工具调用)
```

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
| `skills/claude-cli/SKILL.md` | 教 Claude Code 怎么调 claude CLI(方案/分析/审视型任务) |
| `install.sh` / `uninstall.sh` | 一键安装/卸载(自动建 `~/.local/bin`、铺 wrapper、检测 PATH) |

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/AmorErwanc/ai-cli-skills/main/uninstall.sh | bash
```

只清安装的文件 + zshrc 里的 source 行;项目里的 `.ai-sessions/` 数据**保留**,需要清理自行 `rm -rf`。

## 设计要点

- **默认零配置**:model / effort / 权限全走用户已有的 `~/.codex/config.toml` 和 `~/.claude/settings.json`
- **session 集中管理**:主项目根的 `.ai-sessions/`,跨 worktree 共享
- **name 撞车立即报错**:绝不静默接错 session(防止旧上下文污染新任务)
- **必带 desc**:≥ 15 字,半年后回来还看得懂自己起的 session 在干啥
- **safety 约束自动注入**:每条 prompt 末尾加"不要 git commit/push",防 AI 乱提交
- **Claude Code skill 集成**:让 agent 学一遍就会用,不用手把手教

详细规则见 `skills/codex-cli/SKILL.md` 和 `skills/claude-cli/SKILL.md`。

## License

MIT
