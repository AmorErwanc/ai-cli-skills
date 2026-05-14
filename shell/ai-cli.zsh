# AI CLI wrapper: 用 claude/codex CLI 起 session、续聊、查看、删除
# 默认走 ~/.codex/config.toml 和 ~/.claude/settings.json
# 数据存放: <主项目根>/.ai-sessions/<cli>-<name>/{sid,desc,last.txt,full.log}

# 脚本自身路径(每个公共函数会用,在 _ai_* 内部函数丢失时 re-source 自己)
typeset -g _AI_CLI_SELF="${(%):-%x}"
[[ -z "$_AI_CLI_SELF" || ! -f "$_AI_CLI_SELF" ]] && _AI_CLI_SELF="$HOME/.config/zsh/ai-cli.zsh"

# ============================================================
# 内部辅助函数(_ 前缀)
# ============================================================

_ai_session_root() {
  # 返回应该放 .ai-sessions/ 的目录(永远是主项目根,worktree 内共享主项目)
  if git rev-parse --git-dir &>/dev/null; then
    local common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
    # 主 worktree: common_dir = ".git" 或 "<repo>/.git";worktree: 绝对路径
    case "$common_dir" in
      /*) dirname "$common_dir" ;;          # 绝对路径(从 worktree 跑)
      *)  echo "$(cd "$(dirname "$common_dir")" && pwd)" ;;  # 相对路径
    esac
  else
    # 非 git 仓库,用当前目录
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

  codex exec ${=skip_flag} ${=extra} -o "$sdir/last.txt" "$full_prompt" 2>&1 | tee -a "$sdir/full.log"

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

  codex exec resume ${=skip_flag} -o "$sdir/last.txt" "$sid" "$full_prompt" 2>&1 | tee -a "$sdir/full.log"

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

  claude -p --session-id "$sid" ${=extra} "$full_prompt" 2>&1 | tee -a "$sdir/full.log" | tee "$sdir/last.txt"

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

  claude -p -r "$sid" "$full_prompt" 2>&1 | tee -a "$sdir/full.log" | tee "$sdir/last.txt"

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
    # 用 full.log 的 mtime 表示"最后活跃时间"(没有就回退到 sid)
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
    # zsh: 数组下标从 1
    sdir="${matches[1]}"
    [[ -z "$sdir" || ! -d "$sdir" ]] && sdir="${matches[0]}"  # bash fallback
  fi

  local desc=""
  [[ -f "$sdir/desc" ]] && desc=$(head -1 "$sdir/desc")

  rm -rf "$sdir"
  echo "✓ 已删除: $(basename "$sdir")"
  [[ -n "$desc" ]] && echo "   desc: $desc"
}
