# AI CLI wrapper: 用 claude/codex CLI 起 session、续聊、查看、删除
# 默认走 ~/.codex/config.toml 和 ~/.claude/settings.json
# 数据存放: <主项目根>/.ai-sessions/<cli>-<name>/{sid,desc,last.txt,full.log}
#
# Watchdog: 每 30s 检查 full.log 大小,60s 无新输出 → warn,5 分钟 → 自动 kill + 记 incident
# Incidents: ~/.ai-sessions-incidents/<ts>-<cli>-<name>/ 包含 summary/stack/lsof/env 等

# 脚本自身路径(每个公共函数会用,在 _ai_* 内部函数丢失时 re-source 自己)
typeset -g _AI_CLI_SELF="${(%):-%x}"
[[ -z "$_AI_CLI_SELF" || ! -f "$_AI_CLI_SELF" ]] && _AI_CLI_SELF="$HOME/.config/zsh/ai-cli.zsh"

# Watchdog 参数(环境变量可覆盖)
typeset -g _AI_WD_INTERVAL="${AI_WATCHDOG_INTERVAL:-30}"   # 检查间隔(秒)
typeset -g _AI_WD_WARN="${AI_WATCHDOG_WARN_CHECKS:-2}"     # 多少次无更新→ warn(默认 2*30=60s)
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

_ai_safety_suffix() {
  echo "约束:不要执行 git commit 或 git push。"
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
    echo "=== 当时活跃的 ai-codex / ai-claude 命令 ==="
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

ai-codex() {
  [[ -z "${functions[_ai_validate_name]}" ]] && source "${_AI_CLI_SELF:-$HOME/.config/zsh/ai-cli.zsh}" 2>/dev/null
  local name="$1" desc="$2" prompt="$3"
  shift 3 2>/dev/null
  local model="" effort=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m) model="$2"; shift 2 ;;
      -e) effort="$2"; shift 2 ;;
      *) echo "❌ 未知参数: $1"; return 1 ;;
    esac
  done

  _ai_validate_name "$name" || return 1
  _ai_validate_desc "$desc" || return 1
  [[ -z "$prompt" ]] && { echo "❌ prompt 不能为空"; return 1; }

  _ai_init
  local sdir="$(_ai_session_root)/.ai-sessions/codex-$name"
  if [[ -d "$sdir" ]]; then
    echo "❌ session 'codex-$name' 已存在"
    echo "   续聊: ai-codex-c $name \"...\""
    echo "   重置: ai-rm codex-$name && ai-codex $name \"...\" \"...\""
    return 1
  fi

  mkdir -p "$sdir"
  printf '%s\n' "$desc" > "$sdir/desc"

  local skip_flag=$(_ai_skip_git_flag)
  local extra=""
  [[ -n "$model" ]] && extra="$extra -m $model"
  [[ -n "$effort" ]] && extra="$extra -c model_reasoning_effort=$effort"

  local full_prompt="$prompt

$(_ai_safety_suffix)"

  _ai_append_round_header "$sdir/full.log" "new" 1 "$full_prompt"

  # 启动 codex 在子 shell 后台(watchdog 监控 sdir/full.log)
  (
    codex exec ${=skip_flag} ${=extra} -o "$sdir/last.txt" "$full_prompt" </dev/null 2>&1 | tee -a "$sdir/full.log"
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
  echo "✓ codex session 'codex-$name' 已创建(sid: ${sid:0:8}…)"
}

ai-codex-c() {
  [[ -z "${functions[_ai_validate_name]}" ]] && source "${_AI_CLI_SELF:-$HOME/.config/zsh/ai-cli.zsh}" 2>/dev/null
  if [[ $# -ne 2 ]]; then
    echo "❌ 用法: ai-codex-c <name> \"<prompt>\""
    return 1
  fi
  local name="$1" prompt="$2"

  _ai_validate_name "$name" || return 1
  [[ -z "$prompt" ]] && { echo "❌ prompt 不能为空"; return 1; }

  local sdir="$(_ai_session_root)/.ai-sessions/codex-$name"
  if [[ ! -d "$sdir" ]]; then
    echo "❌ session 'codex-$name' 不存在"
    echo "   新起: ai-codex $name \"<desc≥15字>\" \"<prompt>\""
    return 1
  fi

  local sid=$(cat "$sdir/sid")
  local skip_flag=$(_ai_skip_git_flag)
  local round=$(( $(_ai_round_count "$sdir/full.log") + 1 ))

  local full_prompt="$prompt

$(_ai_safety_suffix)"

  _ai_append_round_header "$sdir/full.log" "resume" "$round" "$full_prompt"

  (
    codex exec resume ${=skip_flag} -o "$sdir/last.txt" "$sid" "$full_prompt" </dev/null 2>&1 | tee -a "$sdir/full.log"
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

ai-claude() {
  [[ -z "${functions[_ai_validate_name]}" ]] && source "${_AI_CLI_SELF:-$HOME/.config/zsh/ai-cli.zsh}" 2>/dev/null
  local name="$1" desc="$2" prompt="$3"
  shift 3 2>/dev/null
  local model="" effort=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m) model="$2"; shift 2 ;;
      -e) effort="$2"; shift 2 ;;
      *) echo "❌ 未知参数: $1"; return 1 ;;
    esac
  done

  _ai_validate_name "$name" || return 1
  _ai_validate_desc "$desc" || return 1
  [[ -z "$prompt" ]] && { echo "❌ prompt 不能为空"; return 1; }

  _ai_init
  local sdir="$(_ai_session_root)/.ai-sessions/claude-$name"
  if [[ -d "$sdir" ]]; then
    echo "❌ session 'claude-$name' 已存在"
    echo "   续聊: ai-claude-c $name \"...\""
    echo "   重置: ai-rm claude-$name && ai-claude $name \"...\" \"...\""
    return 1
  fi

  mkdir -p "$sdir"
  local sid=$(uuidgen | tr A-Z a-z)
  printf '%s\n' "$sid" > "$sdir/sid"
  printf '%s\n' "$desc" > "$sdir/desc"

  local extra=""
  [[ -n "$model" ]] && extra="$extra --model $model"
  [[ -n "$effort" ]] && extra="$extra --effort $effort"

  local full_prompt="$prompt

$(_ai_safety_suffix)"

  _ai_append_round_header "$sdir/full.log" "new" 1 "$full_prompt"

  (
    claude -p --session-id "$sid" ${=extra} "$full_prompt" </dev/null 2>&1 | tee -a "$sdir/full.log" | tee "$sdir/last.txt"
  ) &
  local pipeline_pid=$!

  _ai_watchdog $pipeline_pid "$sdir" claude "$name" &
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
    echo "⚠ claude exit code: $exit_code"
    return $exit_code
  fi

  echo ""
  echo "✓ claude session 'claude-$name' 已创建(sid: ${sid:0:8}…)"
}

ai-claude-c() {
  [[ -z "${functions[_ai_validate_name]}" ]] && source "${_AI_CLI_SELF:-$HOME/.config/zsh/ai-cli.zsh}" 2>/dev/null
  if [[ $# -ne 2 ]]; then
    echo "❌ 用法: ai-claude-c <name> \"<prompt>\""
    return 1
  fi
  local name="$1" prompt="$2"

  _ai_validate_name "$name" || return 1
  [[ -z "$prompt" ]] && { echo "❌ prompt 不能为空"; return 1; }

  local sdir="$(_ai_session_root)/.ai-sessions/claude-$name"
  if [[ ! -d "$sdir" ]]; then
    echo "❌ session 'claude-$name' 不存在"
    echo "   新起: ai-claude $name \"<desc≥15字>\" \"<prompt>\""
    return 1
  fi

  local sid=$(cat "$sdir/sid")
  local round=$(( $(_ai_round_count "$sdir/full.log") + 1 ))

  local full_prompt="$prompt

$(_ai_safety_suffix)"

  _ai_append_round_header "$sdir/full.log" "resume" "$round" "$full_prompt"

  (
    claude -p -r "$sid" "$full_prompt" </dev/null 2>&1 | tee -a "$sdir/full.log" | tee "$sdir/last.txt"
  ) &
  local pipeline_pid=$!

  _ai_watchdog $pipeline_pid "$sdir" claude "$name" &
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
    echo "⚠ claude exit code: $exit_code"
    return $exit_code
  fi

  echo ""
  echo "✓ claude 'claude-$name' Round $round 完成"
}

ai-sessions() {
  [[ -z "${functions[_ai_validate_name]}" ]] && source "${_AI_CLI_SELF:-$HOME/.config/zsh/ai-cli.zsh}" 2>/dev/null
  local root="$(_ai_session_root)/.ai-sessions"
  if [[ ! -d "$root" ]]; then
    echo "当前目录无 .ai-sessions/(尚未使用过 ai-cli)"
    return 0
  fi

  local found=0
  local fmt="%-7s  %-22s  %-50s  %s\n"
  printf "$fmt" "CLI" "NAME" "DESC" "UPDATED"
  printf -- "%.0s-" {1..96}; echo

  for sdir in "$root"/*/; do
    [[ -d "$sdir" ]] || continue
    local base=$(basename "$sdir")
    [[ "$base" == .* ]] && continue
    local cli="${base%%-*}"
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
    printf "$fmt" "$cli" "$name" "$desc" "$updated"
    found=$((found + 1))
  done

  if (( found == 0 )); then
    echo "(空)"
  fi
}

ai-rm() {
  [[ -z "${functions[_ai_validate_name]}" ]] && source "${_AI_CLI_SELF:-$HOME/.config/zsh/ai-cli.zsh}" 2>/dev/null
  if [[ $# -ne 1 ]]; then
    echo "❌ 一次只能删一个: ai-rm <name>"
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
      echo "请显式: ai-rm codex-$input 或 ai-rm claude-$input"
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
ai-incidents() {
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
    echo "查看详情:  ai-incidents <incident-id 关键字>"
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
ai-update() {
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
