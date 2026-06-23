#!/usr/bin/env bash
# ai-cli-skills 一键安装
# 用法:curl -fsSL https://raw.githubusercontent.com/AmorErwanc/ai-cli-skills/main/install.sh | bash
set -e

REPO="AmorErwanc/ai-cli-skills"
RAW="https://raw.githubusercontent.com/$REPO/main"

echo "📦 安装 ai-cli-skills..."
echo ""

# === 硬依赖检查 ===
for cmd in zsh uuidgen git curl; do
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

# === 建目录 + 拉文件 ===
mkdir -p ~/.config/zsh ~/.local/bin ~/.claude/skills/codex-cli ~/.claude/skills/claude-cli

echo "下载 shell 函数..."
curl -fsSL "$RAW/shell/ai-cli.zsh" -o ~/.config/zsh/ai-cli.zsh

echo "下载 agent wrapper..."
curl -fsSL "$RAW/bin/agent" -o ~/.local/bin/agent
chmod +x ~/.local/bin/agent

echo "下载 skill 文档..."
curl -fsSL "$RAW/skills/codex-cli/SKILL.md"  -o ~/.claude/skills/codex-cli/SKILL.md
curl -fsSL "$RAW/skills/claude-cli/SKILL.md" -o ~/.claude/skills/claude-cli/SKILL.md

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
