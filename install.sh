#!/usr/bin/env bash
# ai-cli-skills 一键安装
# 用法:curl -fsSL https://raw.githubusercontent.com/AmorErwanc/ai-cli-skills/main/install.sh | bash
set -e

REPO="AmorErwanc/ai-cli-skills"
RAW="https://raw.githubusercontent.com/$REPO/main"

echo "📦 安装 ai-cli-skills..."
echo ""

# === 依赖检查 ===
for cmd in zsh uuidgen git curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ 缺少依赖:$cmd";  exit 1; }
done

# === CLI 提示(不强制装) ===
command -v codex >/dev/null 2>&1 || echo "⚠  codex CLI 未装:https://github.com/openai/codex"
command -v claude >/dev/null 2>&1 || echo "⚠  claude CLI 未装:https://docs.claude.com/en/docs/claude-code"

# === 建目录 + 拉文件 ===
mkdir -p ~/.config/zsh ~/.claude/skills/codex-cli ~/.claude/skills/claude-cli

echo "下载 shell 函数..."
curl -fsSL "$RAW/shell/ai-cli.zsh" -o ~/.config/zsh/ai-cli.zsh

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

echo ""
echo "🎉 安装完成"
echo ""
echo "下一步:"
echo "  1) 重启终端 或 source ~/.zshrc"
echo "  2) 跑 ai-sessions 验证(应显示 '当前目录无 .ai-sessions/...')"
echo "  3) 起测试 session:"
echo "     ai-codex test-it \"测试 ai-codex 命令是否可用且能正常返回\" \"回 OK 即可,不要做任何事\""
echo ""
echo "以后想更新到最新版:跑 ai-update(等同重跑这个 install.sh)"
