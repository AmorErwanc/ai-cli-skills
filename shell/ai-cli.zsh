# AI CLI wrapper: 用 claude/codex CLI 起 session、续聊、查看、删除
# 默认走 ~/.codex/config.toml 和 ~/.claude/settings.json
# 数据存放: <主项目根>/.ai-sessions/<cli>-<name>/{sid,desc,last.txt,full.log}
#
# Watchdog: 每 30s 检查 full.log 大小,120s 无新输出 → warn,5 分钟 → 自动 kill + 记 incident
# Incidents: ~/.ai-sessions-incidents/<ts>-<cli>-<name>/ 包含 summary/stack/lsof/env 等

# 脚本自身路径(每个公共函数会用,在 _ai_* 内部函数丢失时 re-source 自己)
typeset -g _AI_CLI_SELF="${(%):-%x}"
[[ -z "$_AI_CLI_SELF" || ! -f "$_AI_CLI_SELF" ]] && _AI_CLI_SELF="$HOME/.config/zsh/ai-cli.zsh"

# Watchdog 参数(环境变量可覆盖)
typeset -g _AI_WD_INTERVAL="${AI_WATCHDOG_INTERVAL:-30}"   # 检查间隔(秒)
typeset -g _AI_WD_WARN="${AI_WATCHDOG_WARN_CHECKS:-4}"     # 多少次无更新→ warn(默认 4*30=120s)
typeset -g _AI_WD_KILL="${AI_WATCHDOG_KILL_CHECKS:-10}"    # 多少次无更新→ kill(默认 10*30=5min)

# ============================================================
# 内部辅助函数(_ 前缀)
# ============================================================

_ai_session_root() {
  # 返回应该放 .ai-sessions/ 的目录(永远是主项目根,worktree 内共享主项目)
  if git rev-parse --git-dir &>/dev/null; then
    local common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
    case "$common_dir" in
      /*) dirname "$common_dir" ;;
      *)  echo "$(cd "$(dirname "$common_dir")" && pwd)" ;;
    esac
  else
    echo "$PWD"
  fi
}

_ai_init() {
  local root="$(_ai_session_root)/.ai-sessions"
  [[ -d "$root" ]] || mkdir -p "$root"
  [[ -f "$root/.gitignore" ]] || echo "*" > "$root/.gitignore"
}

_ai_validate_name() {
  local n="$1"
  if [[ -z "$n" ]]; then
    echo "❌ name 不能为空"
    return 1
  fi
  if ! [[ "$n" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "❌ name 必须是 kebab-case(小写字母/数字/连字符): '$n'"
    return 1
  fi
  return 0
}

_ai_validate_desc() {
  local d="$1"
  if [[ -z "$d" ]]; then
    echo "❌ desc 必填(描述这个 session 在做什么)"
    return 1
  fi
  local len=$(printf '%s' "$d" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
  if (( len < 15 )); then
    echo "❌ desc 至少 15 字符(当前 $len):告诉自己/未来的你这个 session 在做什么"
    echo "   当前 desc: $d"
    return 1
  fi
  return 0
}

_ai_skip_git_flag() {
  if git rev-parse --git-dir &>/dev/null; then
    echo ""
  else
    echo "--skip-git-repo-check"
  fi
}

_ai_apply_cwd() {
  # -C/--cwd 公共处理:dir 非空就 cd,失败报错;dir 为空直接通过
  local dir="$1"
  [[ -z "$dir" ]] && return 0
  if [[ ! -d "$dir" ]]; then
    echo "❌ -C 目录不存在: $dir"
    return 1
  fi
  cd "$dir" || { echo "❌ -C cd 失败: $dir"; return 1; }
  return 0
}


_ai_require_arg() {
  # 校验带值 flag 后面真有值(防止 -f 后没传文件路径就 shift 出界)
  # 用法: _ai_require_arg <flag-name> "$2"
  local flag="$1" value="$2"
  if [[ -z "$value" || "$value" == -* ]]; then
    echo "❌ $flag 缺少值"
    return 1
  fi
  return 0
}

_ai_read_prompt_file() {
  # 读 -f 指定的 prompt 文件:校验存在、非空,算绝对路径(防 -C cd 后找不到)
  # 成功时把内容写到全局 _AI_RPF_CONTENT,绝对路径写到 _AI_RPF_ABS
  local file="$1"
  _AI_RPF_CONTENT=""
  _AI_RPF_ABS=""
  if [[ -z "$file" ]]; then
    echo "❌ -f 文件路径不能为空"
    return 1
  fi
  if [[ ! -f "$file" ]]; then
    echo "❌ -f 文件不存在: $file"
    return 1
  fi
  local abs_file
  abs_file="$(cd "$(dirname "$file")" 2>/dev/null && pwd)/$(basename "$file")"
  if [[ ! -f "$abs_file" ]]; then
    echo "❌ -f 解析绝对路径失败: $file"
    return 1
  fi
  local content
  content="$(<"$abs_file")"
  if [[ -z "$content" ]]; then
    echo "❌ -f 文件为空: $file"
    return 1
  fi
  _AI_RPF_CONTENT="$content"
  _AI_RPF_ABS="$abs_file"
  return 0
}

_ai_safety_suffix() {
  cat <<'EOF'
约束:
- 不要执行 git commit 或 git push。
- 不要调用 agent 命令起新 session,避免任务套娃。你就是被外层 agent 起来的 session,直接完成任务。
EOF
}

# ------------------------------------------------------------
# 起外部 CLI 前的可选同步钩子
#
# 背景:用户可能有一套"全局提示词动态生成"机制(源文件 → 生成产物),把触发点挂在
# zshrc 的 codex()/claude() 包装函数上。但 agent wrapper 是**独立 zsh 进程、不读 zshrc**,
# 那层包装对它根本不存在——于是走 agent 起的 session 会静默跳过同步,外部 AI 拿到旧提示词,
# 且不报任何错。这里把这条漏掉的路径补上。
#
# 两个刻意的设计:
# 1. 脚本不存在 → 静默跳过。本项目是开源的,别人机器上没有这东西,不该因此报错
# 2. 同步失败 → 只 warn 不阻断。跟 zshrc 那层"失败就拒绝启动"的取舍不同:交互终端里
#    用户能立刻看到并处理,而 agent 常在后台/并发跑,阻断整个任务的代价远大于用旧提示词
#
# AI_SYNC_HOOK 环境变量可覆盖路径;显式设成空字符串则完全禁用。
# 注意用 ${VAR-default} 而非 ${VAR:-default}:前者才能让 AI_SYNC_HOOK="" 真正禁用。
# ------------------------------------------------------------
_ai_sync_instructions() {
  local hook="${AI_SYNC_HOOK-$HOME/.agents/bin/sync-instructions}"
  [[ -n "$hook" && -x "$hook" ]] || return 0
  # 丢 stdout(正常的进度输出会干扰 session 输出),保留 stderr(失败原因要看得到)
  "$hook" >/dev/null \
    || echo "⚠ 全局提示词同步失败($hook),继续用现有提示词起 session" >&2
  return 0
}

# ------------------------------------------------------------
# 模型 / 思考强度白名单
#
# 白名单是刻意收窄的:两个 CLI 各自认识的取值远不止这些(codex 还支持
# none/minimal/ultra 三档 effort、十几个 gpt-5.x 模型),但暴露太多档位
# 只会让调用方选择困难、选错。这里只放"确认可用 + 日常真的会用"的几个。
# 想用白名单外的值 → 改本机 config,或直接用原生 CLI。
#
# 传错值一律本地立刻报错(不透传给 CLI),避免等打到服务端才炸。
# ------------------------------------------------------------

# effort 白名单:两个 CLI 的公共可用档(codex/claude 都吃这五个)
_ai_validate_effort() {
  local e="$1"
  case "$e" in
    low|medium|high|xhigh|max) return 0 ;;
    *)
      echo "❌ -e 不支持 '$e'"
      echo "   可选: low / medium / high / xhigh / max"
      return 1
      ;;
  esac
}

# codex 模型白名单
_ai_validate_codex_model() {
  local m="$1"
  case "$m" in
    gpt-5.6-sol|gpt-5.6-luna) return 0 ;;
    *)
      echo "❌ -m 不支持 '$m'"
      echo "   codex 可选: gpt-5.6-sol / gpt-5.6-luna"
      return 1
      ;;
  esac
}

# claude 模型白名单 + 长上下文映射
#
# 关键:三个 alias 一律解析成 [1m] 长上下文变体。裸 alias(opus)拿到的是标准
# 上下文窗口,而本机默认配的就是 opus[1m]——如果这里不映射,"显式指定 opus"
# 反而会把上下文从 1M 悄悄缩回标准档,是纯粹的能力降级且无任何提示。
_ai_resolve_claude_model() {
  local m="$1"
  case "$m" in
    opus)   echo "opus[1m]" ;;
    sonnet) echo "sonnet[1m]" ;;
    fable)  echo "fable[1m]" ;;
    *)
      echo "❌ -m 不支持 '$m'" >&2
      echo "   claude 可选: opus / sonnet / fable(均自动用 1M 长上下文变体)" >&2
      return 1
      ;;
  esac
  return 0
}

# 把 session 用过的 model / effort 记进 session 目录,供续聊沿用
#
# ⚠️ 调用方必须在**所有校验都通过之后**才调这个函数。写在校验前的话,一个非法值
# 会先落盘再被拒——之后每轮续聊都读回这个脏值、每轮都失败,session 直接报废
# (用户得手动 rm 才能救回来)。
#
# 写失败只 warn 不中断:记录写不进去顶多是续聊没法沿用,不该因此让本轮任务跑不成。
_ai_save_session_opts() {
  local sdir="$1" model="$2" effort="$3"
  if [[ -n "$model" ]]; then
    printf '%s\n' "$model" > "$sdir/model" 2>/dev/null \
      || echo "⚠ 写 $sdir/model 失败,续聊将无法沿用模型(本轮不受影响)" >&2
  fi
  if [[ -n "$effort" ]]; then
    printf '%s\n' "$effort" > "$sdir/effort" 2>/dev/null \
      || echo "⚠ 写 $sdir/effort 失败,续聊将无法沿用思考强度(本轮不受影响)" >&2
  fi
  return 0
}

# 续聊校验失败时的提示:能走到"沿用后校验"这步说明显式传的值已经合法,
# 那非法值必然来自 session 记录文件(被手改 / 旧版本遗留)
_ai_hint_dirty_session_opt() {
  local sdir="$1" which="$2"
  echo "   ↑ 该值来自 session 记录 $sdir/$which(被手改过?)"
  echo "     删掉它可重置为走本机 config:  rm $sdir/$which"
}

# 注:续聊的"沿用首轮"逻辑内联在 _agent_*_c 里(两行读文件),不单独抽函数——
# zsh 函数改不了调用者的 local 变量,抽出来反而要绕全局变量,得不偿失。
#
# 为什么要沿用:不沿用的话,首轮 -m gpt-5.6-luna 起的 session 一续聊就掉回
# config 默认模型——同一个 session 跨轮换了脑子,且完全无提示。
# 显式传值会覆盖并**更新**记录,之后各轮沿用新值(换档就是换了,不是只换一轮)。

# claude peer 专属 prompt 注入:任务分工 + 套娃 codex 姿势硬规则
# 注:这不是"安全约束",是"实操规则"——peer 想起 codex 子任务时如果用错姿势,
# codex 会被连带杀。这条规则保证 peer 每次都看得到,不依赖它主动读 SKILL.md
_ai_claude_nesting_rule() {
  cat <<'EOF'
任务分工:涉及开发请交给 codex(否则忽略本段):

- 这次任务如果涉及**正式开发**(写新功能 / 重构 / 大量改代码 / 加测试),
  请用 agent codex new 把任务交给 codex 干,不要你自己动手:
  - 后端类(Go/Rust/Java/数据库/分布式) → codex 强项,直接交
  - 前端类(React/Vue/CSS/UI 框架) → 你自己干更顺手,claude 在前端比 codex 强
- 协作类任务(出方案 / 跨项目读 / 改少量基础文件如 deploy.yaml / 配置 / 文档 / 单文件小改) → 你自己干,不必绕 codex
- 不涉及开发就忽略上面分工。

下面是你起 agent codex new 套娃任务的姿势硬规则(违反会被连带杀,实测踩坑总结):

1. 用 Bash tool 跑 agent codex new 时,**禁止**用 `run_in_background: true`——
   那是 Claude Code 自己管的 background pool,你退出时会把里面任务一起清理掉
   (实测:codex sleep 90s 任务,你退出 11s 后 codex 8s 内被杀,产出文件根本没生成)

2. 必须用 `run_in_background: false`(同步 bash) + 命令本身用 shell `&` 控制后台,
   shell `&` 是真 fork detach,子进程被 init 收养,你退出也杀不掉

3. 三种典型姿势:
   - 单 codex 同步: `agent codex new task "..." -C ...`(不带 &,你等它完)
   - 并行 N 个全部等完: `agent codex new a "..." -C ... & ; agent codex new b "..." -C ... & ; wait`
   - 并行不等就退(让用户手动接力): `agent codex new a "..." -C ... & ; agent codex new b "..." -C ... &`(不带 wait)

不打算起 codex 套娃就忽略上面姿势规则,继续干你自己的事。
EOF
}

_ai_round_count() {
  local logf="$1"
  if [[ -f "$logf" ]]; then
    grep -c '^=== Round' "$logf" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

_ai_append_round_header() {
  local logf="$1" kind="$2" round="$3" user_prompt="$4"
  {
    echo ""
    echo "=== Round $round @ $(date '+%Y-%m-%d %H:%M:%S') | $kind ==="
    echo "[user]"
    echo "$user_prompt"
    echo ""
    echo "[output]"
  } >> "$logf"
}

# 解析 claude -p --output-format stream-json 的 JSON 流
# 把每行 JSON 事件转成人类可读输出(stdout),同时旁路把 result.result 写到 last.txt
# 用法: <claude stream-json output> | _ai_parse_claude_stream <last_txt_path>
# 依赖: jq(macOS brew install jq)
_ai_parse_claude_stream() {
  local last_txt="$1"
  # jq 不可用 → fallback 直接透传原始 JSON 流(避免完全 break)
  if ! command -v jq >/dev/null 2>&1; then
    echo "⚠ jq 未安装,无法解析 claude stream-json,full.log 将是原始 JSON。装一下:brew install jq" >&2
    tee "$last_txt"
    return 0
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # 容错:每行单独解析,失败就原样吐出
    # 注:必须用 local var=$(...) 一步声明赋值,zsh 在 typeset -g 全局变量存在时
    # local var 单独一行后跟 var=$(...) 赋值会把 var=value 泄漏到 stdout
    local event_type=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)
    if [[ -z "$event_type" ]]; then
      echo "$line"
      continue
    fi

    case "$event_type" in
      system|rate_limit_event)
        # 跳过元信息和速率限制噪音
        :
        ;;
      assistant)
        # 遍历 message.content 数组,按 type 分发
        printf '%s' "$line" | jq -r '
          .message.content[]? |
          if .type == "thinking" then
            "[thinking…]"
          elif .type == "tool_use" then
            "[tool: \(.name)] \(.input | tojson)"
          elif .type == "text" then
            .text
          else
            "[unknown content type: \(.type)]"
          end
        ' 2>/dev/null
        ;;
      user)
        # tool_result(可能很长,截断 500 字符)
        printf '%s' "$line" | jq -r '
          .message.content[]? |
          if .type == "tool_result" then
            (if (.content | type) == "string" then .content else (.content | tojson) end) as $c
            | if ($c | length) > 500 then "[tool_result] " + ($c[:500]) + "…(truncated)" else "[tool_result] " + $c end
          else
            "[unknown user content: \(.type)]"
          end
        ' 2>/dev/null
        ;;
      result)
        # final 抽到 last.txt,full.log 输出一行汇总
        local final_text=$(printf '%s' "$line" | jq -r '.result // empty' 2>/dev/null)
        local duration_ms=$(printf '%s' "$line" | jq -r '.duration_ms // 0' 2>/dev/null)
        local cost=$(printf '%s' "$line" | jq -r '.total_cost_usd // 0' 2>/dev/null)
        if [[ -n "$final_text" ]]; then
          printf '%s' "$final_text" > "$last_txt"
        fi
        echo "[result] ${duration_ms}ms | \$${cost}"
        ;;
      *)
        echo "[$event_type] $(printf '%s' "$line" | jq -c '. | del(.type)' 2>/dev/null)"
        ;;
    esac
  done
}

# 杀进程树:用 ps + awk 一次性找所有后代,SIGKILL 杀光
_ai_kill_tree() {
  local root=$1
  # 用 printf 而非 print 避免换行(awk -v 不支持多行 known 参数)
  local known_pids="$root"
  local iter=0
  while (( iter < 10 )); do
    iter=$((iter + 1))
    local new_pids=$(ps -A -o pid,ppid 2>/dev/null | awk -v known="$known_pids" '
      BEGIN {
        n = split(known, arr, " ")
        for (i = 1; i <= n; i++) parent[arr[i]] = 1
      }
      NR > 1 {
        if (parent[$2] && !parent[$1]) {
          printf "%s ", $1
          parent[$1] = 1
        }
      }
    ')
    if [[ -z "${new_pids// /}" ]]; then
      break
    fi
    known_pids="$known_pids $new_pids"
  done
  # 一次性 SIGKILL 杀光
  echo $known_pids | xargs kill -KILL 2>/dev/null
  return 0
}

# BFS 子进程树,找像 codex/claude 的实际 CLI 进程 PID(不是 zsh wrapper)
_ai_find_cli_pid() {
  local parent_pid="$1"
  local pids=$(pgrep -P $parent_pid 2>/dev/null)
  for p in ${(z)pids}; do
    local cmd=$(ps -p $p -o command= 2>/dev/null)
    if [[ "$cmd" == *codex* ]] || [[ "$cmd" == *claude* ]]; then
      echo $p
      return 0
    fi
    local grandchild=$(_ai_find_cli_pid $p)
    [[ -n "$grandchild" ]] && { echo $grandchild; return 0; }
  done
  return 1
}

# 收集 incident 诊断包到 ~/.ai-sessions-incidents/<ts>-<cli>-<name>/
_ai_capture_incident() {
  local cli_pid="$1" sdir="$2" cli="$3" name="$4" reason="$5"
  # reason: "warn" 或 "kill"

  local ts=$(date '+%Y-%m-%dT%H-%M-%S')
  local incident_dir="$HOME/.ai-sessions-incidents/${ts}-${cli}-${name}"
  mkdir -p "$incident_dir"

  # === summary.md ===
  {
    echo "# Incident: $cli-$name @ $ts"
    echo ""
    echo "- **触发原因**: $reason ($([ "$reason" = "warn" ] && echo "60s 无新输出" || echo "5 分钟无新输出,已 kill"))"
    echo "- **CLI 进程 PID**: $cli_pid"
    echo "- **CLI 是否还活着**: $(kill -0 $cli_pid 2>/dev/null && echo yes || echo no)"
    echo "- **cwd**: $PWD"
    echo "- **session dir**: $sdir"
    echo "- **session sid**: $(cat "$sdir/sid" 2>/dev/null || echo '<未生成>')"
    echo "- **full.log 大小**: $(wc -c < "$sdir/full.log" 2>/dev/null | tr -d ' ') bytes"
    echo "- **诊断目录**: $incident_dir"
    echo ""
    echo "## 发我诊断"
    echo "\`\`\`bash"
    echo "tar czf /tmp/incident.tar.gz -C \$HOME/.ai-sessions-incidents '$(basename $incident_dir)'"
    echo "\`\`\`"
  } > "$incident_dir/summary.md"

  # === process.txt ===
  if kill -0 $cli_pid 2>/dev/null; then
    ps -p $cli_pid -o pid,ppid,stat,etime,time,rss,wchan,command > "$incident_dir/process.txt" 2>&1
  else
    echo "进程已退出,无法获取 ps 信息" > "$incident_dir/process.txt"
  fi

  # === concurrent.txt(总是收集,看 race) ===
  {
    echo "=== 当时活跃的 codex / claude 进程 ==="
    pgrep -fl 'codex exec|claude -p' 2>/dev/null || echo "(无)"
  } > "$incident_dir/concurrent.txt"

  # === env.txt(总是收集,看版本) ===
  # 用 timeout 包裹外部 CLI 调用,防止 codex/claude --version 自身卡死把 watchdog 也带卡
  {
    echo "=== Tool Versions ==="
    echo "codex: $(timeout 3 codex --version 2>&1 | tr '\n' ';' | head -c 200)"
    echo "claude: $(timeout 3 claude --version 2>&1 | tr '\n' ';' | head -c 200)"
    echo "node: $(timeout 3 node --version 2>&1)"
    echo ""
    echo "=== System ==="
    echo "macOS: $(sw_vers -productVersion 2>/dev/null)"
    echo "kernel: $(uname -r)"
    echo "uptime: $(uptime)"
    echo ""
    echo "=== Memory ==="
    vm_stat 2>/dev/null | head -8
    echo ""
    echo "=== Disk(home)==="
    df -h "$HOME" 2>/dev/null | head -2
  } > "$incident_dir/env.txt"

  # === kill 时的重诊断(sample / lsof) ===
  if [[ "$reason" == "kill" ]]; then
    # 用真正的 CLI 进程(找子进程树里的 codex/claude),sample 才有意义
    local sample_pid=$(_ai_find_cli_pid $cli_pid)
    [[ -z "$sample_pid" ]] && sample_pid=$cli_pid

    if kill -0 $sample_pid 2>/dev/null; then
      # sample / lsof 都加 timeout 兜底
      timeout 8 sample $sample_pid 3 -file "$incident_dir/stack.sample.txt" 2>&1 | head -5 > "$incident_dir/.sample.meta" 2>&1
      timeout 5 lsof -p $sample_pid > "$incident_dir/lsof.txt" 2>&1
      timeout 5 lsof -p $sample_pid -i > "$incident_dir/lsof-net.txt" 2>&1
    else
      echo "进程已退出,无法 sample/lsof" > "$incident_dir/stack.sample.txt"
    fi

    # 进程树(macOS 无 pstree,用 ps grep)
    ps -ef 2>/dev/null | grep -E "codex|claude|$cli_pid" | grep -v grep > "$incident_dir/pstree.txt"

    # prompt-info(最后一轮的 prompt 头 800 字符)
    if [[ -f "$sdir/full.log" ]]; then
      local prompt_chars=$(awk '/^\[user\]/{flag=1; chars=0; next} /^\[output\]/{flag=0} flag {print}' "$sdir/full.log" | tail -100 | wc -c | tr -d ' ')
      {
        echo "prompt 字符数(估算): $prompt_chars"
        echo ""
        echo "=== 最后一轮 prompt 头 800 字符 ==="
        awk '/^\[user\]/{flag=1; next} /^\[output\]/{flag=0} flag' "$sdir/full.log" | tail -50 | head -20 | cut -c1-800
      } > "$incident_dir/prompt-info.txt"
    fi

    # full.log 快照
    cp "$sdir/full.log" "$incident_dir/full.log.snapshot" 2>/dev/null
  fi

  echo "" >&2
  echo "📋 Incident 已记录: $incident_dir" >&2
  if [[ "$reason" == "kill" ]]; then
    echo "   发我诊断: tar czf /tmp/incident.tar.gz -C ~/.ai-sessions-incidents '$(basename $incident_dir)'" >&2
  fi
}

# Watchdog: 后台监控 full.log mtime,卡死时 warn / kill + capture incident
_ai_watchdog() {
  local pipeline_pid="$1" sdir="$2" cli="$3" name="$4"
  local logf="$sdir/full.log"
  local stale_count=0 last_mtime=0 warned=0

  while kill -0 $pipeline_pid 2>/dev/null; do
    sleep $_AI_WD_INTERVAL

    if ! kill -0 $pipeline_pid 2>/dev/null; then
      break
    fi

    local cur_mtime=$(stat -f '%m' "$logf" 2>/dev/null || echo 0)

    if (( cur_mtime == last_mtime )); then
      stale_count=$((stale_count + 1))

      # Warn
      if (( stale_count == _AI_WD_WARN )) && (( warned == 0 )); then
        warned=1
        local secs=$((_AI_WD_INTERVAL * _AI_WD_WARN))
        echo "" >&2
        echo "⚠ ai-${cli} '$name' 已 ${secs}s 无新输出,可能卡死(到 $((_AI_WD_INTERVAL * _AI_WD_KILL))s 自动 kill)" >&2
        echo -ne "\a" >&2
        osascript -e "display notification \"$cli '$name' 已 ${secs}s 无输出\" with title \"⚠ ai-cli 疑似卡死\"" 2>/dev/null
      fi

      # Kill
      if (( stale_count >= _AI_WD_KILL )); then
        local secs=$((_AI_WD_INTERVAL * _AI_WD_KILL))
        echo "" >&2
        echo "❌ ai-${cli} '$name' 已 ${secs}s 无新输出,记录 incident 并自动终止" >&2
        echo -ne "\a\a" >&2

        # 找真正的 CLI PID 抓诊断
        local real_pid=$(_ai_find_cli_pid $pipeline_pid)
        [[ -z "$real_pid" ]] && real_pid=$pipeline_pid

        # 先 touch marker(让主 shell 立刻能退出 polling,不被后续 capture 慢操作拖累)
        touch "$sdir/.killed-by-watchdog"

        # 用子 shell 隔离 incident 收集(避免内部子进程不 reap 影响后续 wait)
        ( _ai_capture_incident "$real_pid" "$sdir" "$cli" "$name" "kill" </dev/null >&2 2>&1 ) &
        local cap_pid=$!
        # 给 capture 最多 15 秒(防 codex/claude --version 之类卡死把 watchdog 也带卡)
        local cap_wait=0
        while ps -p $cap_pid >/dev/null 2>&1 && (( cap_wait < 30 )); do
          sleep 0.5
          cap_wait=$((cap_wait + 1))
        done
        (( cap_wait >= 30 )) && {
          echo "⚠ capture 超时(15s),强制结束" >&2
          kill -KILL $cap_pid 2>/dev/null
          _ai_kill_tree $cap_pid
        }

        # 杀整棵进程树
        _ai_kill_tree $pipeline_pid

        osascript -e "display notification \"$cli '$name' 已 kill,诊断包已存\" with title \"❌ ai-cli 已终止\"" 2>/dev/null
        return 1
      fi
    else
      stale_count=0
      warned=0
      last_mtime=$cur_mtime
    fi
  done
}

# ============================================================
# 公共命令
# ============================================================

_agent_codex_new() {
  [[ -z "${functions[_ai_validate_name]}" ]] && source "${_AI_CLI_SELF:-$HOME/.config/zsh/ai-cli.zsh}" 2>/dev/null
  local name="$1" desc="$2"
  shift 2 2>/dev/null
  local prompt=""
  # 第 3 个位置参数:不以 - 开头 → prompt 字符串
  if [[ $# -gt 0 && "$1" != -* ]]; then
    prompt="$1"; shift
  fi
  local model="" effort="" cwd="" prompt_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m) _ai_require_arg -m "$2" || return 1; model="$2"; shift 2 ;;
      -e) _ai_require_arg -e "$2" || return 1; effort="$2"; shift 2 ;;
      -C|--cwd) _ai_require_arg -C "$2" || return 1; cwd="$2"; shift 2 ;;
      -f) _ai_require_arg -f "$2" || return 1; prompt_file="$2"; shift 2 ;;
      *) echo "❌ 未知参数: $1"; return 1 ;;
    esac
  done

  # 位置参数 prompt 和 -f 二选一
  if [[ -n "$prompt" && -n "$prompt_file" ]]; then
    echo "❌ 不能同时传 <prompt> 位置参数和 -f file,只用一种"
    return 1
  fi
  if [[ -n "$prompt_file" ]]; then
    _ai_read_prompt_file "$prompt_file" || return 1
    prompt="$_AI_RPF_CONTENT"
    prompt_file="$_AI_RPF_ABS"
  fi

  _ai_validate_name "$name" || return 1
  _ai_validate_desc "$desc" || return 1
  [[ -z "$prompt" ]] && { echo "❌ prompt 不能为空(用 \"<prompt>\" 或 -f <file>)"; return 1; }
  [[ -n "$model" ]]  && { _ai_validate_codex_model "$model" || return 1; }
  [[ -n "$effort" ]] && { _ai_validate_effort "$effort" || return 1; }
  _ai_apply_cwd "$cwd" || return 1

  _ai_init
  local sdir="$(_ai_session_root)/.ai-sessions/codex-$name"
  if [[ -d "$sdir" ]]; then
    echo "❌ session 'codex-$name' 已存在"
    echo "   续聊: agent codex c $name \"...\""
    echo "   重置: agent rm codex-$name && agent codex new $name \"...\" \"...\""
    return 1
  fi

  mkdir -p "$sdir"
  printf '%s\n' "$desc" > "$sdir/desc"
  # 记下本轮 model/effort,续聊时沿用(不传则不落文件 = 一直走 config 默认)
  _ai_save_session_opts "$sdir" "$model" "$effort"
  # archive prompt 文件(如果走 -f)留底,方便复盘
  if [[ -n "$prompt_file" ]]; then
    cp "$prompt_file" "$sdir/prompt.md" || echo "⚠ archive prompt 文件失败,session 仍会继续(详见 stderr)" >&2
  fi

  local skip_flag=$(_ai_skip_git_flag)
  # 用数组而非字符串拼接:模型名/配置值可能含空格或 glob 字符,
  # ${=extra} 那种 word-split 会踩坑,数组展开是安全的
  local -a extra=()
  [[ -n "$model" ]]  && extra+=(-m "$model")
  [[ -n "$effort" ]] && extra+=(-c "model_reasoning_effort=$effort")

  local full_prompt="$prompt

$(_ai_safety_suffix)"

  _ai_sync_instructions
  _ai_append_round_header "$sdir/full.log" "new" 1 "$full_prompt"

  # 启动 codex 在子 shell 后台(watchdog 监控 sdir/full.log)
  (
    codex exec ${=skip_flag} "${extra[@]}" -o "$sdir/last.txt" "$full_prompt" </dev/null 2>&1 | tee -a "$sdir/full.log"
  ) &
  local pipeline_pid=$!

  _ai_watchdog $pipeline_pid "$sdir" codex "$name" &
  local wd_pid=$!

  # Polling 等 pipeline 自然死或被 watchdog kill
  # 用 ps -p 而非 wait/kill -0,绕开 zsh job control 在子 shell 上的不确定行为
  while ps -p $pipeline_pid >/dev/null 2>&1 && [[ ! -f "$sdir/.killed-by-watchdog" ]]; do
    sleep 0.5
  done
  local exit_code=0
  if [[ -f "$sdir/.killed-by-watchdog" ]]; then
    exit_code=137
    rm -f "$sdir/.killed-by-watchdog"
  fi

  # 清理 watchdog(它可能还活着,kill 它)
  kill -KILL $wd_pid 2>/dev/null
  # 等 wd_pid 真正死(ps -p)
  local wd_wait=0
  while ps -p $wd_pid >/dev/null 2>&1 && (( wd_wait < 6 )); do
    sleep 0.5
    wd_wait=$((wd_wait + 1))
  done

  if (( exit_code != 0 )); then
    echo ""
    echo "⚠ codex exit code: $exit_code(可能被 watchdog kill 或其他错误)"
    return $exit_code
  fi

  local sid=$(grep -oE 'session id: [0-9a-f-]+' "$sdir/full.log" | head -1 | awk '{print $3}')
  if [[ -z "$sid" ]]; then
    echo ""
    echo "⚠ 无法抓取 session id,清理残留"
    rm -rf "$sdir"
    return 1
  fi
  printf '%s\n' "$sid" > "$sdir/sid"

  echo ""
  echo ""
  echo "✓ codex session 'codex-$name' 已创建"
  echo "  sid: $sid"
  echo "  原生 CLI 跳转: codex exec resume $sid \"<新 prompt>\""
  echo "       或 codex resume(交互 picker)"
}

_agent_codex_c() {
  [[ -z "${functions[_ai_validate_name]}" ]] && source "${_AI_CLI_SELF:-$HOME/.config/zsh/ai-cli.zsh}" 2>/dev/null
  local name="$1"
  shift 1 2>/dev/null
  local prompt=""
  # 第 2 个位置参数:不以 - 开头 → prompt 字符串
  if [[ $# -gt 0 && "$1" != -* ]]; then
    prompt="$1"; shift
  fi
  local model="" effort="" cwd="" prompt_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m) _ai_require_arg -m "$2" || return 1; model="$2"; shift 2 ;;
      -e) _ai_require_arg -e "$2" || return 1; effort="$2"; shift 2 ;;
      -C|--cwd) _ai_require_arg -C "$2" || return 1; cwd="$2"; shift 2 ;;
      -f) _ai_require_arg -f "$2" || return 1; prompt_file="$2"; shift 2 ;;
      *) echo "❌ 未知参数: $1"; return 1 ;;
    esac
  done

  # 位置参数 prompt 和 -f 二选一
  if [[ -n "$prompt" && -n "$prompt_file" ]]; then
    echo "❌ 不能同时传 <prompt> 位置参数和 -f file,只用一种"
    return 1
  fi
  if [[ -n "$prompt_file" ]]; then
    _ai_read_prompt_file "$prompt_file" || return 1
    prompt="$_AI_RPF_CONTENT"
    prompt_file="$_AI_RPF_ABS"
  fi

  _ai_validate_name "$name" || return 1
  [[ -z "$prompt" ]] && { echo "❌ prompt 不能为空(用法: <name> \"<prompt>\" [-C dir] 或 <name> -f <file>)"; return 1; }
  [[ -n "$model" ]]  && { _ai_validate_codex_model "$model" || return 1; }
  [[ -n "$effort" ]] && { _ai_validate_effort "$effort" || return 1; }
  _ai_apply_cwd "$cwd" || return 1

  local sdir="$(_ai_session_root)/.ai-sessions/codex-$name"
  if [[ ! -d "$sdir" ]]; then
    echo "❌ session 'codex-$name' 不存在"
    echo "   新起: agent codex new $name \"<desc≥15字>\" \"<prompt>\""
    return 1
  fi

  local sid=$(cat "$sdir/sid")
  local skip_flag=$(_ai_skip_git_flag)
  local round=$(( $(_ai_round_count "$sdir/full.log") + 1 ))

  # 本轮没显式传 → 沿用 session 记下的值(首轮或上次覆盖的);
  # 显式传了 → 覆盖,并更新记录供后续轮沿用
  [[ -z "$model"  && -f "$sdir/model"  ]] && model=$(<"$sdir/model")
  [[ -z "$effort" && -f "$sdir/effort" ]] && effort=$(<"$sdir/effort")

  # 再校验一次"最终生效值":沿用来的值也可能是脏的(session 文件被手改 / 旧版本遗留)。
  # 显式传的值前面已校验过,所以走到这里失败的必然来自 session 记录
  [[ -n "$model" ]]  && { _ai_validate_codex_model "$model" || { _ai_hint_dirty_session_opt "$sdir" model; return 1; } }
  [[ -n "$effort" ]] && { _ai_validate_effort "$effort"     || { _ai_hint_dirty_session_opt "$sdir" effort; return 1; } }

  # 全部校验通过,才更新记录(顺序不能反,详见 _ai_save_session_opts 注释)
  _ai_save_session_opts "$sdir" "$model" "$effort"

  # archive prompt 文件(如果走 -f)留底,以 round 命名
  if [[ -n "$prompt_file" ]]; then
    cp "$prompt_file" "$sdir/prompt-round-$round.md" || echo "⚠ archive prompt 文件失败,session 仍会继续(详见 stderr)" >&2
  fi

  local -a extra=()
  [[ -n "$model" ]]  && extra+=(-m "$model")
  [[ -n "$effort" ]] && extra+=(-c "model_reasoning_effort=$effort")

  local full_prompt="$prompt

$(_ai_safety_suffix)"

  _ai_sync_instructions
  _ai_append_round_header "$sdir/full.log" "resume" "$round" "$full_prompt"

  (
    codex exec resume ${=skip_flag} "${extra[@]}" -o "$sdir/last.txt" "$sid" "$full_prompt" </dev/null 2>&1 | tee -a "$sdir/full.log"
  ) &
  local pipeline_pid=$!

  _ai_watchdog $pipeline_pid "$sdir" codex "$name" &
  local wd_pid=$!

  # Polling 等 pipeline 自然死或被 watchdog kill
  # 用 ps -p 而非 wait/kill -0,绕开 zsh job control 在子 shell 上的不确定行为
  while ps -p $pipeline_pid >/dev/null 2>&1 && [[ ! -f "$sdir/.killed-by-watchdog" ]]; do
    sleep 0.5
  done
  local exit_code=0
  if [[ -f "$sdir/.killed-by-watchdog" ]]; then
    exit_code=137
    rm -f "$sdir/.killed-by-watchdog"
  fi

  # 清理 watchdog(它可能还活着,kill 它)
  kill -KILL $wd_pid 2>/dev/null
  # 等 wd_pid 真正死(ps -p)
  local wd_wait=0
  while ps -p $wd_pid >/dev/null 2>&1 && (( wd_wait < 6 )); do
    sleep 0.5
    wd_wait=$((wd_wait + 1))
  done

  if (( exit_code != 0 )); then
    echo ""
    echo "⚠ codex exit code: $exit_code"
    return $exit_code
  fi

  echo ""
  echo "✓ codex 'codex-$name' Round $round 完成"
}

_agent_claude_new() {
  [[ -z "${functions[_ai_validate_name]}" ]] && source "${_AI_CLI_SELF:-$HOME/.config/zsh/ai-cli.zsh}" 2>/dev/null
  local name="$1" desc="$2"
  shift 2 2>/dev/null
  local prompt=""
  if [[ $# -gt 0 && "$1" != -* ]]; then
    prompt="$1"; shift
  fi
  local model="" effort="" cwd="" prompt_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m) _ai_require_arg -m "$2" || return 1; model="$2"; shift 2 ;;
      -e) _ai_require_arg -e "$2" || return 1; effort="$2"; shift 2 ;;
      -C|--cwd) _ai_require_arg -C "$2" || return 1; cwd="$2"; shift 2 ;;
      -f) _ai_require_arg -f "$2" || return 1; prompt_file="$2"; shift 2 ;;
      *) echo "❌ 未知参数: $1"; return 1 ;;
    esac
  done

  if [[ -n "$prompt" && -n "$prompt_file" ]]; then
    echo "❌ 不能同时传 <prompt> 位置参数和 -f file,只用一种"
    return 1
  fi
  if [[ -n "$prompt_file" ]]; then
    _ai_read_prompt_file "$prompt_file" || return 1
    prompt="$_AI_RPF_CONTENT"
    prompt_file="$_AI_RPF_ABS"
  fi

  _ai_validate_name "$name" || return 1
  _ai_validate_desc "$desc" || return 1
  [[ -z "$prompt" ]] && { echo "❌ prompt 不能为空(用 \"<prompt>\" 或 -f <file>)"; return 1; }
  # 校验 + 解析成 [1m] 长上下文变体(注:不能写成 local x=$(...) || return,
  # 那样 || 判的是 local 的返回值而非命令替换的,校验会静默失效)
  local model_resolved=""
  if [[ -n "$model" ]]; then
    model_resolved=$(_ai_resolve_claude_model "$model") || return 1
  fi
  [[ -n "$effort" ]] && { _ai_validate_effort "$effort" || return 1; }
  _ai_apply_cwd "$cwd" || return 1

  _ai_init
  local sdir="$(_ai_session_root)/.ai-sessions/claude-$name"
  if [[ -d "$sdir" ]]; then
    echo "❌ session 'claude-$name' 已存在"
    echo "   续聊: agent claude c $name \"...\""
    echo "   重置: agent rm claude-$name && agent claude new $name \"...\" \"...\""
    return 1
  fi

  mkdir -p "$sdir"
  local sid=$(uuidgen | tr A-Z a-z)
  printf '%s\n' "$sid" > "$sdir/sid"
  printf '%s\n' "$desc" > "$sdir/desc"
  # session 里存**原始 alias**(opus),不存映射后的 opus[1m]——续聊读回来要能再过一次白名单
  _ai_save_session_opts "$sdir" "$model" "$effort"
  # archive prompt 文件(如果走 -f)留底,方便复盘
  if [[ -n "$prompt_file" ]]; then
    cp "$prompt_file" "$sdir/prompt.md" || echo "⚠ archive prompt 文件失败,session 仍会继续(详见 stderr)" >&2
  fi

  local -a extra=()
  [[ -n "$model_resolved" ]] && extra+=(--model "$model_resolved")
  [[ -n "$effort" ]]         && extra+=(--effort "$effort")

  # claude peer:不加 safety 约束(协作者完整能力放开),但追加套娃硬规则
  # (避免 peer 起 codex 用错姿势被连带杀,实测踩坑;详见 _ai_claude_nesting_rule)
  local full_prompt="$prompt

$(_ai_claude_nesting_rule)"

  _ai_sync_instructions
  _ai_append_round_header "$sdir/full.log" "new" 1 "$full_prompt"

  (
    claude -p --output-format stream-json --verbose --session-id "$sid" "${extra[@]}" "$full_prompt" </dev/null 2>&1 \
      | _ai_parse_claude_stream "$sdir/last.txt" \
      | tee -a "$sdir/full.log"
  ) &
  local pipeline_pid=$!

  # claude 不起 watchdog——协作 peer 定位,允许它等多个并行 codex 套娃跑很久;
  # 真卡死靠用户 Ctrl-C 兜底。codex 那边仍有 watchdog 保护工具型任务。
  while ps -p $pipeline_pid >/dev/null 2>&1; do
    sleep 0.5
  done
  wait $pipeline_pid 2>/dev/null
  local exit_code=$?

  if (( exit_code != 0 )); then
    echo ""
    echo "⚠ claude exit code: $exit_code"
    return $exit_code
  fi

  echo ""
  echo ""
  echo "✓ claude session 'claude-$name' 已创建"
  echo "  sid: $sid"
  echo "  原生 CLI 跳转: claude --resume $sid"
  echo "       (打开 TUI 续聊那个 session)"
}

_agent_claude_c() {
  [[ -z "${functions[_ai_validate_name]}" ]] && source "${_AI_CLI_SELF:-$HOME/.config/zsh/ai-cli.zsh}" 2>/dev/null
  local name="$1"
  shift 1 2>/dev/null
  local prompt=""
  if [[ $# -gt 0 && "$1" != -* ]]; then
    prompt="$1"; shift
  fi
  local model="" effort="" cwd="" prompt_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m) _ai_require_arg -m "$2" || return 1; model="$2"; shift 2 ;;
      -e) _ai_require_arg -e "$2" || return 1; effort="$2"; shift 2 ;;
      -C|--cwd) _ai_require_arg -C "$2" || return 1; cwd="$2"; shift 2 ;;
      -f) _ai_require_arg -f "$2" || return 1; prompt_file="$2"; shift 2 ;;
      *) echo "❌ 未知参数: $1"; return 1 ;;
    esac
  done

  if [[ -n "$prompt" && -n "$prompt_file" ]]; then
    echo "❌ 不能同时传 <prompt> 位置参数和 -f file,只用一种"
    return 1
  fi
  if [[ -n "$prompt_file" ]]; then
    _ai_read_prompt_file "$prompt_file" || return 1
    prompt="$_AI_RPF_CONTENT"
    prompt_file="$_AI_RPF_ABS"
  fi

  _ai_validate_name "$name" || return 1
  [[ -z "$prompt" ]] && { echo "❌ prompt 不能为空(用法: <name> \"<prompt>\" [-C dir] 或 <name> -f <file>)"; return 1; }
  # 显式传的值先校验一轮(早失败)。model 这里只校验不取结果,解析放到沿用之后统一做
  [[ -n "$model" ]]  && { _ai_resolve_claude_model "$model" >/dev/null || return 1; }
  [[ -n "$effort" ]] && { _ai_validate_effort "$effort" || return 1; }
  _ai_apply_cwd "$cwd" || return 1

  local sdir="$(_ai_session_root)/.ai-sessions/claude-$name"
  if [[ ! -d "$sdir" ]]; then
    echo "❌ session 'claude-$name' 不存在"
    echo "   新起: agent claude new $name \"<desc≥15字>\" \"<prompt>\""
    return 1
  fi

  local sid=$(cat "$sdir/sid")
  local round=$(( $(_ai_round_count "$sdir/full.log") + 1 ))

  # 本轮没显式传 → 沿用 session 记下的 alias;显式传了 → 覆盖并更新记录
  [[ -z "$model"  && -f "$sdir/model"  ]] && model=$(<"$sdir/model")
  [[ -z "$effort" && -f "$sdir/effort" ]] && effort=$(<"$sdir/effort")

  # 校验 + 解析"最终生效值"成 [1m] 变体。沿用来的值也可能是脏的(session 文件被手改),
  # 所以这里要再过一遍。显式值前面已校验,走到这里失败的必然来自 session 记录
  local model_resolved=""
  if [[ -n "$model" ]]; then
    model_resolved=$(_ai_resolve_claude_model "$model") \
      || { _ai_hint_dirty_session_opt "$sdir" model; return 1; }
  fi
  [[ -n "$effort" ]] && { _ai_validate_effort "$effort" || { _ai_hint_dirty_session_opt "$sdir" effort; return 1; } }

  # 全部校验通过,才更新记录——绝不能写在校验前:传错值会先落盘,
  # 之后每轮续聊读回脏值全部失败,session 直接报废
  _ai_save_session_opts "$sdir" "$model" "$effort"

  # archive prompt 文件(如果走 -f)留底,以 round 命名
  if [[ -n "$prompt_file" ]]; then
    cp "$prompt_file" "$sdir/prompt-round-$round.md" || echo "⚠ archive prompt 文件失败,session 仍会继续(详见 stderr)" >&2
  fi

  local -a extra=()
  [[ -n "$model_resolved" ]] && extra+=(--model "$model_resolved")
  [[ -n "$effort" ]]         && extra+=(--effort "$effort")

  # claude peer:同 new 函数,追加套娃硬规则(详见 _ai_claude_nesting_rule)
  local full_prompt="$prompt

$(_ai_claude_nesting_rule)"

  _ai_sync_instructions
  _ai_append_round_header "$sdir/full.log" "resume" "$round" "$full_prompt"

  (
    claude -p --output-format stream-json --verbose -r "$sid" "${extra[@]}" "$full_prompt" </dev/null 2>&1 \
      | _ai_parse_claude_stream "$sdir/last.txt" \
      | tee -a "$sdir/full.log"
  ) &
  local pipeline_pid=$!

  # claude 不起 watchdog(同 new 函数说明)
  while ps -p $pipeline_pid >/dev/null 2>&1; do
    sleep 0.5
  done
  wait $pipeline_pid 2>/dev/null
  local exit_code=$?

  if (( exit_code != 0 )); then
    echo ""
    echo "⚠ claude exit code: $exit_code"
    return $exit_code
  fi

  echo ""
  echo "✓ claude 'claude-$name' Round $round 完成"
}

_agent_ls() {
  [[ -z "${functions[_ai_validate_name]}" ]] && source "${_AI_CLI_SELF:-$HOME/.config/zsh/ai-cli.zsh}" 2>/dev/null

  if (( $# > 1 )); then
    echo "❌ agent ls 只接受 0 或 1 个过滤参数(传了 $#): $*"
    return 1
  fi
  local filter="$1"
  if [[ -n "$filter" && "$filter" != "codex" && "$filter" != "claude" ]]; then
    echo "❌ 过滤参数必须是 codex 或 claude(当前: '$filter')"
    return 1
  fi

  local root="$(_ai_session_root)/.ai-sessions"
  if [[ ! -d "$root" ]]; then
    echo "当前目录无 .ai-sessions/(尚未使用过 agent)"
    return 0
  fi

  local fmt="%-22s  %-50s  %s\n"
  local total=0

  for target_cli in codex claude; do
    [[ -n "$filter" && "$filter" != "$target_cli" ]] && continue

    # 收集当前 cli 的 sessions
    local sessions=()
    for sdir in "$root"/*(N/); do
      local base=$(basename "$sdir")
      [[ "$base" == .* ]] && continue
      local cli="${base%%-*}"
      [[ "$cli" == "$target_cli" ]] && sessions+=("$sdir")
    done

    (( ${#sessions[@]} == 0 )) && continue

    # 不是第一组时加空行分隔
    (( total > 0 )) && echo ""
    echo "[$target_cli] ${#sessions[@]} session(s)"
    printf "$fmt" "NAME" "DESC" "UPDATED"
    printf -- "%.0s-" {1..86}; echo

    for sdir in "${sessions[@]}"; do
      local base=$(basename "$sdir")
      local name="${base#*-}"
      local desc=""
      if [[ -f "$sdir/desc" ]]; then
        desc=$(head -1 "$sdir/desc")
        local len=$(printf '%s' "$desc" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
        if (( len > 50 )); then
          desc=$(printf '%s' "$desc" | cut -c1-50)"…"
        fi
      fi
      local updated="?"
      local probe="$sdir/full.log"
      [[ -f "$probe" ]] || probe="$sdir/sid"
      if [[ -f "$probe" ]]; then
        updated=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$probe" 2>/dev/null || echo "?")
      fi
      printf "$fmt" "$name" "$desc" "$updated"
      total=$((total + 1))
    done
  done

  if (( total == 0 )); then
    if [[ -n "$filter" ]]; then
      echo "(无 $filter session)"
    else
      echo "(空)"
    fi
  fi
}

_agent_rm() {
  [[ -z "${functions[_ai_validate_name]}" ]] && source "${_AI_CLI_SELF:-$HOME/.config/zsh/ai-cli.zsh}" 2>/dev/null
  if [[ $# -ne 1 ]]; then
    echo "❌ 一次只能删一个: agent rm <name>"
    echo "   <name> 可以是短名(audit-x)或完整名(codex-audit-x)"
    return 1
  fi
  local input="$1"
  local root="$(_ai_session_root)/.ai-sessions"
  [[ ! -d "$root" ]] && { echo "❌ 当前无 .ai-sessions/"; return 1; }

  local sdir=""
  if [[ -d "$root/$input" ]]; then
    sdir="$root/$input"
  else
    local matches=()
    [[ -d "$root/codex-$input" ]] && matches+=("$root/codex-$input")
    [[ -d "$root/claude-$input" ]] && matches+=("$root/claude-$input")

    if (( ${#matches[@]} == 0 )); then
      echo "❌ 未找到 '$input' 的 session"
      return 1
    fi
    if (( ${#matches[@]} > 1 )); then
      echo "⚠ '$input' 在多个 CLI 下都存在:"
      for m in "${matches[@]}"; do echo "   $(basename "$m")"; done
      echo "请显式: agent rm codex-$input 或 agent rm claude-$input"
      return 1
    fi
    sdir="${matches[1]}"
    [[ -z "$sdir" || ! -d "$sdir" ]] && sdir="${matches[0]}"
  fi

  local desc=""
  [[ -f "$sdir/desc" ]] && desc=$(head -1 "$sdir/desc")

  rm -rf "$sdir"
  echo "✓ 已删除: $(basename "$sdir")"
  [[ -n "$desc" ]] && echo "   desc: $desc"
}

# 查看 / 管理 incidents
_agent_incidents() {
  local root="$HOME/.ai-sessions-incidents"

  # 列出全部
  if [[ $# -eq 0 ]]; then
    if [[ ! -d "$root" ]] || (( $(ls "$root" 2>/dev/null | wc -l) == 0 )); then
      echo "无 incident($root 为空或不存在)"
      return 0
    fi

    local fmt="%-30s  %-8s  %-30s  %s\n"
    printf "$fmt" "INCIDENT" "CLI" "NAME" "REASON"
    printf -- "%.0s-" {1..90}; echo

    for d in "$root"/*/; do
      [[ -d "$d" ]] || continue
      local base=$(basename "$d")
      # base 格式: 2026-05-22T17-11-codex-task-name
      local ts="${base:0:19}"        # 2026-05-22T17-11-22(到秒)
      local rest="${base:20}"         # codex-task-name
      local cli="${rest%%-*}"
      local name="${rest#*-}"
      local reason="-"
      [[ -f "$d/summary.md" ]] && reason=$(grep -oE '触发原因\*\*: [a-z]+' "$d/summary.md" | awk '{print $NF}')
      printf "$fmt" "$ts" "$cli" "${name:0:30}" "$reason"
    done
    echo ""
    echo "查看详情:  agent incidents <incident-id 关键字>"
    echo "全部清理:  rm -rf $root"
    return 0
  fi

  # 看详情
  local query="$1"
  local matches=()
  for d in "$root"/*/; do
    [[ -d "$d" ]] || continue
    [[ "$(basename "$d")" == *"$query"* ]] && matches+=("$d")
  done

  if (( ${#matches[@]} == 0 )); then
    echo "❌ 未找到匹配 '$query' 的 incident"
    return 1
  fi
  if (( ${#matches[@]} > 1 )); then
    echo "⚠ 匹配 '$query' 的有多个,请精确:"
    for m in "${matches[@]}"; do echo "   $(basename "$m")"; done
    return 1
  fi

  local d="${matches[1]}"
  [[ -z "$d" || ! -d "$d" ]] && d="${matches[0]}"

  echo "📋 Incident: $(basename "$d")"
  echo "   路径: $d"
  echo ""
  cat "$d/summary.md" 2>/dev/null
  echo ""
  echo "=== 文件清单 ==="
  ls -la "$d"
  echo ""
  echo "发我诊断的命令:"
  echo "  tar czf /tmp/incident.tar.gz -C $root '$(basename "$d")'"
}

# 一键更新 ai-cli-skills 到最新版
_agent_update() {
  echo "📦 拉取最新版 ai-cli-skills..."
  echo ""
  if curl -fsSL https://raw.githubusercontent.com/AmorErwanc/ai-cli-skills/main/install.sh | bash; then
    echo ""
    echo "✓ 更新完成"
    echo "  下一步: source ~/.zshrc 或重启终端,新版本生效"
  else
    echo ""
    echo "❌ 更新失败,检查网络或 GitHub 是否可访问"
    return 1
  fi
}

# ============================================================
# agent 统一入口 dispatcher
# ============================================================
#
# 用法:
#   agent codex  new <name> <desc> <prompt> [-m model] [-e effort] [-C dir]
#   agent codex  c   <name> <prompt> [-m model] [-e effort] [-C dir]
#   agent claude new <name> <desc> <prompt> [-m model] [-e effort] [-C dir]
#   agent claude c   <name> <prompt> [-m model] [-e effort] [-C dir]
#   agent ls                       # 列 session
#   agent rm <name>                # 删 session
#   agent incidents [<id>]         # 看 watchdog 抓的卡死诊断
#   agent update                   # 一键更新到最新版
#   agent help | -h | --help       # 用法

_agent_usage() {
  cat <<'EOF'
agent — AI session 管理(codex / claude 非交互调用 + 多 session 并行 + watchdog 防卡死)

用法:
  起 session(新):
    agent codex  new <name> <desc> (<prompt> | -f file) [-m M] [-e E] [-C dir]
    agent claude new <name> <desc> (<prompt> | -f file) [-m M] [-e E] [-C dir]

  续聊:
    agent codex  c <name> (<prompt> | -f file) [-m M] [-e E] [-C dir]
    agent claude c <name> (<prompt> | -f file) [-m M] [-e E] [-C dir]

  管理:
    agent ls [codex|claude]        列 session(可按 cli 过滤)
    agent rm <name>                删 session(name 可短可全)
    agent incidents [<id>]         查 watchdog 抓的卡死诊断
    agent update                   一键更新到最新版

  帮助:
    agent help                     本帮助
    agent codex help               codex 子命令详细用法(含 -f 文件用法示例)
    agent claude help              claude 子命令详细用法

参数:
  <name>     kebab-case 短名(小写字母/数字/连字符)
  <desc>     session 描述,≥ 15 字符(仅 new 必填),例: "审查 redis 缓存方案的取舍"
  <prompt>   位置参数 prompt 字符串(短任务用这个,但**不能以 - 开头**——以 - 开头会被当成 flag,
             此时必须走 -f file)
  -m         模型(不传 = 走本机 config,这是默认且推荐)
               codex  : gpt-5.6-sol | gpt-5.6-luna
               claude : opus | sonnet | fable(均自动用 1M 长上下文变体)
  -e         思考强度(不传 = 走本机 config): low | medium | high | xhigh | max
  -C, --cwd  工作目录(可选,不传 = 当前 PWD)
  -f         从文件读 prompt(prompt 较长、含反引号/$ 等特殊字符、或以 - 开头时用,跟 <prompt> 互斥)
             文件内容会自动 archive 到 <session>/prompt.md(new)或 prompt-round-N.md(续聊)

关于 -m / -e:
  · 不传 = 走本机配置(~/.codex/config.toml / ~/.claude/settings.json),多数情况就该不传
  · new 时传了会记进 session,续聊自动沿用同一档,不会中途换脑子
  · 续聊显式传则覆盖,并成为之后各轮的新默认
  · 传白名单外的值直接报错(不透传给 CLI),要用别的值请改本机 config
EOF
}

_agent_codex_help() {
  cat <<'EOF'
agent codex — 起 codex session(开发/实现型任务)

用法:
  agent codex new <name> <desc> (<prompt> | -f file) [-m M] [-e E] [-C dir]
  agent codex c   <name> (<prompt> | -f file) [-m M] [-e E] [-C dir]
  agent codex help

参数:
  <name>     kebab-case 短名
  <desc>     session 描述,≥ 15 字(仅 new 必填),例: "审查 redis 缓存方案的取舍"
  <prompt>   位置参数 prompt 字符串,**不能以 - 开头**(否则会被当成 flag,此时改走 -f)
  -m         模型: gpt-5.6-sol | gpt-5.6-luna
             不传 = 走 ~/.codex/config.toml(默认且推荐)
  -e         思考强度: low | medium | high | xhigh | max
             不传 = 走 ~/.codex/config.toml
  -C, --cwd  工作目录(等价于先 cd 再起,不传 = 当前 PWD)
  -f         从文件读 prompt;以下任一情况推荐用 -f(跟 <prompt> 互斥):
             - prompt 含反引号、$、& 等会被 shell 解析的特殊字符
             - prompt 以 - 开头(否则被误认为 flag)
             - prompt 很长(几行以上)

关于 -m / -e:
  · new 时传了会记进 session,续聊自动沿用同一档,不会中途换脑子
  · 续聊显式传则覆盖,并成为之后各轮的新默认
  · 传白名单外的值直接报错,不透传给 codex(要用别的值请改 ~/.codex/config.toml)

复杂 prompt 推荐写法(heredoc 必须 'EOF' 带单引号,禁止 shell 展开):
  cat > ~/tmp/agent-prompt-foo.md <<'EOF_INNER'
  [目标] 复杂的 prompt 里随便用 ` $ {} 都安全
  EOF_INNER
  agent codex new foo "审查 redis 缓存方案的取舍" -f ~/tmp/agent-prompt-foo.md -C ~/project/myrepo

-f 文件会自动 archive 到 <session>/prompt.md(new)或 prompt-round-N.md(续聊),方便复盘
EOF
}

_agent_claude_help() {
  cat <<'EOF'
agent claude — 起 claude session(方案/分析/审视型任务)

用法:
  agent claude new <name> <desc> (<prompt> | -f file) [-m M] [-e E] [-C dir]
  agent claude c   <name> (<prompt> | -f file) [-m M] [-e E] [-C dir]
  agent claude help

参数:
  <name>     kebab-case 短名
  <desc>     session 描述,≥ 15 字(仅 new 必填),例: "审查 redis 缓存方案的取舍"
  <prompt>   位置参数 prompt 字符串,**不能以 - 开头**(否则会被当成 flag,此时改走 -f)
  -m         模型: opus | sonnet | fable
             三个都自动解析成 1M 长上下文变体(opus → opus[1m]),不会因为显式指定
             模型反而把上下文从 1M 缩回标准档
             不传 = 走 ~/.claude/settings.json(默认且推荐)
  -e         思考强度: low | medium | high | xhigh | max
             不传 = 走 ~/.claude/settings.json
  -C, --cwd  工作目录(等价于先 cd 再起,不传 = 当前 PWD)
  -f         从文件读 prompt;以下任一情况推荐用 -f(跟 <prompt> 互斥):
             - prompt 含反引号、$、& 等会被 shell 解析的特殊字符
             - prompt 以 - 开头(否则被误认为 flag)
             - prompt 很长(几行以上)

关于 -m / -e:
  · new 时传了会记进 session,续聊自动沿用同一档,不会中途换脑子
  · 续聊显式传则覆盖,并成为之后各轮的新默认
  · 传白名单外的值直接报错,不透传给 claude(要用别的值请改 ~/.claude/settings.json)

复杂 prompt 推荐写法(heredoc 必须 'EOF' 带单引号,禁止 shell 展开):
  cat > ~/tmp/agent-prompt-foo.md <<'EOF_INNER'
  [目标] 复杂的 prompt 里随便用 ` $ {} 都安全
  EOF_INNER
  agent claude new foo "审查 redis 缓存方案的取舍" -f ~/tmp/agent-prompt-foo.md -C ~/project/myrepo

-f 文件会自动 archive 到 <session>/prompt.md(new)或 prompt-round-N.md(续聊),方便复盘
EOF
}

_agent_dispatch() {
  [[ -z "${functions[_ai_validate_name]}" ]] && source "${_AI_CLI_SELF:-$HOME/.config/zsh/ai-cli.zsh}" 2>/dev/null

  # 没参数 / help
  if [[ $# -eq 0 || "$1" == "help" || "$1" == "-h" || "$1" == "--help" ]]; then
    _agent_usage
    return 0
  fi

  local sub="$1"; shift

  case "$sub" in
    codex)
      local action="$1"; shift 2>/dev/null
      case "$action" in
        new)                  _agent_codex_new "$@" ;;
        c)                    _agent_codex_c "$@" ;;
        help|-h|--help|"")    _agent_codex_help ;;
        *)
          echo "❌ 未知 codex 子命令: $action" >&2
          _agent_codex_help >&2
          return 1
          ;;
      esac
      ;;
    claude)
      local action="$1"; shift 2>/dev/null
      case "$action" in
        new)                  _agent_claude_new "$@" ;;
        c)                    _agent_claude_c "$@" ;;
        help|-h|--help|"")    _agent_claude_help ;;
        *)
          echo "❌ 未知 claude 子命令: $action" >&2
          _agent_claude_help >&2
          return 1
          ;;
      esac
      ;;
    ls)        _agent_ls "$@" ;;
    rm)        _agent_rm "$@" ;;
    incidents) _agent_incidents "$@" ;;
    update)    _agent_update "$@" ;;
    *)
      echo "❌ 未知子命令: $sub" >&2
      echo "   跑 'agent help' 看用法" >&2
      return 1
      ;;
  esac
}

# 注:不在这里定义顶层 agent() 函数。
# agent 命令统一走 ~/.local/bin/agent wrapper(PATH 优先级 < shell 函数,所以一旦定义
# 函数就会拦截外部 wrapper)。让 wrapper 是唯一入口,避免 shell snapshot 缓存只抓部分
# 函数(比如 agent 有、_agent_dispatch 没)导致命令崩——这种问题在 Claude Code Bash tool
# 等用 shell snapshot 加速启动的环境里特别容易踩。
