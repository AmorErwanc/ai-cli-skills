# Agent 类型档案

每个类型占一个独立目录：

```text
profiles/<type>/
├── profile.conf   # 必填，短配置
└── inject.md      # 可选，追加到用户 prompt 后的类型提示词
```

运行时默认从 `~/.ai-cli-skills/profiles/` 读取；可用环境变量 `AI_PROFILES_DIR` 覆盖，便于测试或使用另一套档案。

## profile.conf 格式

每行一条 `key=value`，允许空行和以 `#` 开头的整行注释。不执行 shell 展开，不允许未知字段。

```conf
cli=codex
model=gpt-5.6-terra
effort=high
safety=on
nesting_rule=off
watchdog=on
sandbox=readonly
```

| 字段 | 必填 | 可选值 | 默认值 |
|---|---|---|---|
| `cli` | 是 | `codex`、`claude` | 无 |
| `model` | 否 | codex：`gpt-5.6-sol`、`gpt-5.6-luna`、`gpt-5.6-terra`；claude：`opus`、`sonnet`、`fable` | 本机 config |
| `effort` | 否 | `low`、`medium`、`high`、`xhigh`、`max` | 本机 config |
| `safety` | 否 | `on`、`off` | codex：`on`；claude：`off` |
| `nesting_rule` | 否 | `on`、`off` | claude：`on`；codex：`off` |
| `watchdog` | 否 | `on`、`off` | codex：`on`；claude：`off` |
| `sandbox` | 否 | `readonly`、`default` | `default`；`readonly` 仅 codex 可用 |

`inject.md` 存放该类型固定注入的提示词。最终顺序为：用户 prompt → `inject.md` → nesting rule → safety suffix，各段之间空一行。

类型目录名使用 kebab-case。以下名称为保留字，不能作为类型名：`ls`、`rm`、`incidents`、`update`、`help`、`type`、`new`、`c`、`codex`、`claude`、`peer`。
