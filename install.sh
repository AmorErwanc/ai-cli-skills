#!/usr/bin/env bash
# ai-cli-skills 一键安装
# 用法:curl -fsSL https://raw.githubusercontent.com/AmorErwanc/ai-cli-skills/main/install.sh | bash
set -e

REPO="AmorErwanc/ai-cli-skills"

echo "📦 安装 ai-cli-skills..."
echo ""

# === 硬依赖检查 ===
for cmd in zsh uuidgen git curl tar; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ 缺少依赖:$cmd";  exit 1; }
done

# === 软依赖检查 ===
# jq:解析 claude stream-json 流式输出(没装就 fallback 原始 JSON 进 log,但不友好)
if ! command -v jq >/dev/null 2>&1; then
  echo "⚠  jq 未装(claude 流式 log 解析需要):brew install jq"
fi

# === CLI 提示(不强制装) ===
command -v codex >/dev/null 2>&1 || echo "⚠  codex CLI 未装:https://github.com/openai/codex"
command -v claude >/dev/null 2>&1 || echo "⚠  claude CLI 未装:https://docs.claude.com/en/docs/claude-code"

# === 下载并校验单一快照 ===
# 在这段完成前绝不创建/覆盖任何安装目标,下载或解包失败不会留下半装状态。
echo "下载完整仓库快照..."
INSTALL_TMP=$(mktemp -d)
trap 'rm -rf "$INSTALL_TMP"' EXIT
ARCHIVE="$INSTALL_TMP/ai-cli-skills.tar.gz"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/main" -o "$ARCHIVE"
tar -xzf "$ARCHIVE" -C "$INSTALL_TMP"
SNAPSHOT_ROOT="$INSTALL_TMP/ai-cli-skills-main"

REQUIRED_FILES=(
  shell/ai-cli.zsh
  bin/agent
  skills/codex-cli/SKILL.md
  skills/claude-cli/SKILL.md
  profiles/README.md
  profiles/review/profile.conf
  profiles/review/inject.md
  profiles/web/profile.conf
  profiles/web/inject.md
)
for required in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "$SNAPSHOT_ROOT/$required" ]; then
    echo "❌ 安装快照缺少: $required"
    exit 1
  fi
done

# === 快照完整后才开始覆盖本机 ===
mkdir -p ~/.config/zsh ~/.local/bin ~/.claude/skills/codex-cli ~/.claude/skills/claude-cli ~/.ai-cli-skills/profiles

echo "安装 shell、wrapper 和 skill 文档..."
cp "$SNAPSHOT_ROOT/shell/ai-cli.zsh" ~/.config/zsh/ai-cli.zsh
cp "$SNAPSHOT_ROOT/bin/agent" ~/.local/bin/agent
chmod +x ~/.local/bin/agent
cp "$SNAPSHOT_ROOT/skills/codex-cli/SKILL.md" ~/.claude/skills/codex-cli/SKILL.md
cp "$SNAPSHOT_ROOT/skills/claude-cli/SKILL.md" ~/.claude/skills/claude-cli/SKILL.md

# 同名内置类型目录整体替换;用户自建的其他类型目录不动。
echo "安装类型档案..."
PROFILE_SRC="$SNAPSHOT_ROOT/profiles"
cp "$PROFILE_SRC/README.md" ~/.ai-cli-skills/profiles/README.md
for profile_dir in "$PROFILE_SRC"/*/; do
  [ -d "$profile_dir" ] || continue
  profile_name=$(basename "$profile_dir")
  rm -rf "$HOME/.ai-cli-skills/profiles/$profile_name"
  cp -R "$profile_dir" "$HOME/.ai-cli-skills/profiles/$profile_name"
done

# === 加 source 行到 zshrc(幂等) ===
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
if [ -f "$ZSHRC" ] && ! grep -qF "ai-cli.zsh" "$ZSHRC"; then
  {
    echo ""
    echo "# === ai-cli-skills (https://github.com/$REPO) ==="
    echo "source ~/.config/zsh/ai-cli.zsh"
  } >> "$ZSHRC"
  echo "✓ 已在 $ZSHRC 末尾加 source 行"
elif [ -f "$ZSHRC" ]; then
  echo "✓ $ZSHRC 已有 source 行,跳过"
else
  echo "⚠  $ZSHRC 不存在,请手动加: source ~/.config/zsh/ai-cli.zsh"
fi

# === 清理老 ai-* wrapper(从旧版升级过来的老用户会有) ===
OLD_WRAPPERS=(ai-codex ai-codex-c ai-claude ai-claude-c ai-sessions ai-rm ai-incidents ai-update ai-cli-wrapper)
CLEANED=0
for w in "${OLD_WRAPPERS[@]}"; do
  if [ -f "$HOME/.local/bin/$w" ]; then
    rm -f "$HOME/.local/bin/$w"
    CLEANED=$((CLEANED + 1))
  fi
done
[ "$CLEANED" -gt 0 ] && echo "✓ 清理了 $CLEANED 个老 ai-* wrapper(请改用 agent 子命令)"

# === PATH 检测:确保 ~/.local/bin 在 PATH 里(给非交互 shell 用) ===
# 用 $HOME 而不是 ~ 在 grep 时更稳
if [ -f "$ZSHRC" ] && ! grep -qE '\.local/bin' "$ZSHRC"; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) PATH_OK=1 ;;
    *) PATH_OK=0 ;;
  esac
  if [ "$PATH_OK" = "0" ]; then
    {
      echo ""
      echo "# === ai-cli-skills: 让 agent wrapper 可被非交互 shell 找到 ==="
      echo 'export PATH="$HOME/.local/bin:$PATH"'
    } >> "$ZSHRC"
    echo "✓ 已在 $ZSHRC 加 PATH 导出行(~/.local/bin)"
  fi
fi

echo ""
echo "🎉 安装完成"
echo ""
echo "下一步:"
echo "  1) 重启终端 或 source ~/.zshrc(让 PATH 和 source 行生效)"
echo "  2) 跑 'agent ls' 验证(应显示 '当前目录无 .ai-sessions/...')"
echo "  3) 起测试 session:"
echo "     agent codex new test-it \"测试 agent 命令是否可用且能正常返回\" \"回 OK 即可,不要做任何事\""
echo ""
echo "命令速查: agent help"
echo "以后想更新:跑 'agent update'(等同重跑这个 install.sh)"
