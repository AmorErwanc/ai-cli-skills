# ai-cli-skills

用 shell 函数 + Claude Code skill 把 **codex CLI** 和 **claude CLI** 的非交互调用包装成「**多 session 并行 + 按 name 续聊 + worktree 隔离开发**」的工作流。

让 Claude Code 调外部 AI 干活时,能像调内部工具一样自然——给个 name 起 session,改完文件 commit 在 worktree,审完 merge 回主分支。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/AmorErwanc/ai-cli-skills/main/install.sh | bash
```

想审脚本再装(推荐):
```bash
curl -O https://raw.githubusercontent.com/AmorErwanc/ai-cli-skills/main/install.sh
less install.sh
bash install.sh
```

装完**重启终端**,跑 `ai-sessions` 验证。

### 依赖

- `zsh`(macOS 默认就是)
- `git`、`curl`、`uuidgen`(macOS 都自带)
- `codex` CLI:https://github.com/openai/codex
- `claude` CLI:https://docs.claude.com/en/docs/claude-code

codex/claude 没装也能装本工具,只是不能跑——装完任何一个就能用对应那一半。

## 用法速览

### 6 个命令

| 命令 | 作用 |
|---|---|
| `ai-codex   <name> "<desc>" "<prompt>"` | 新起 codex session |
| `ai-codex-c <name> "<prompt>"` | 续聊 codex session |
| `ai-claude   <name> "<desc>" "<prompt>"` | 新起 claude session |
| `ai-claude-c <name> "<prompt>"` | 续聊 claude session |
| `ai-sessions` | 列出当前主项目所有 session |
| `ai-rm <name>` | 删除某 session(短名歧义时用完整 `codex-<name>` / `claude-<name>`) |

### 参数

- `<name>`:kebab-case,语义化(`audit-payment`、`refactor-auth`)
- `<desc>`:必填,**≥ 15 字符**,讲清这个 session 在做什么
- `<prompt>`:自然语言任务描述,建议覆盖五个维度——目标 / 背景 / 输入 / 约束 / 产出

可选 flag(默认不传,走 config):
- `-m <model>` 覆盖模型
- `-e <level>` 覆盖思考强度(`low/medium/high/xhigh/max`)

### 一个例子

```bash
# 进项目
cd ~/project/myapp

# 起 codex 起一个开发 session(改文件场景建议先建 worktree,见 SKILL.md)
ai-codex add-cache "给 auth 模块加 Redis 缓存避免重复查 DB" \
  "[目标] 给 src/auth/get-user.ts 加 Redis 缓存。[约束] 不要装新依赖。[产出] 改完一句话说改了啥。"

# 续聊
ai-codex-c add-cache "刚才加的缓存没处理 cache miss 时的 thundering herd,加个 SETNX 锁。"

# 看看所有 session
ai-sessions

# 删
ai-rm add-cache
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

## 文件分工

| 文件 | 干嘛 |
|---|---|
| `shell/ai-cli.zsh` | shell 函数实现(6 个公共命令 + 内部辅助) |
| `skills/codex-cli/SKILL.md` | 教 Claude Code 怎么调 codex CLI(开发型任务、worktree 流程、任务调度) |
| `skills/claude-cli/SKILL.md` | 教 Claude Code 怎么调 claude CLI(方案/分析/审视型任务) |
| `install.sh` / `uninstall.sh` | 一键安装/卸载 |

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
