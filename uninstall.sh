#!/usr/bin/env bash
# ai-cli-skills 卸载
set -e

echo "🗑  卸载 ai-cli-skills..."

rm -f ~/.config/zsh/ai-cli.zsh
rm -rf ~/.claude/skills/codex-cli ~/.claude/skills/claude-cli

ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
if [ -f "$ZSHRC" ]; then
  # 移除 source 行和它的注释行(只删跟本工具相关的,不动别的)
  sed -i.bak -e '/# === ai-cli-skills/d' -e '/source.*ai-cli\.zsh/d' "$ZSHRC"
  rm -f "$ZSHRC.bak"
  echo "✓ 已从 $ZSHRC 移除 source 行"
fi

echo ""
echo "✓ 卸载完成"
echo "  注:项目目录里的 .ai-sessions/ 数据**保留**,需要清理自行 rm -rf"
