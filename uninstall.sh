#!/usr/bin/env bash
# ai-cli-skills 卸载
set -e

echo "🗑  卸载 ai-cli-skills..."

rm -f ~/.config/zsh/ai-cli.zsh
rm -f ~/.local/bin/agent
# 老 wrapper(从旧版升级未清的)一起清掉
rm -f ~/.local/bin/{ai-codex,ai-codex-c,ai-claude,ai-claude-c,ai-sessions,ai-rm,ai-incidents,ai-update,ai-cli-wrapper}
rm -rf ~/.claude/skills/codex-cli ~/.claude/skills/claude-cli

ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
if [ -f "$ZSHRC" ]; then
  # 只删 ai-cli-skills 相关注释 + source 行(PATH 行太通用,可能跟用户自己加的撞,留着)
  sed -i.bak -e '/# === ai-cli-skills/d' -e '/source.*ai-cli\.zsh/d' "$ZSHRC"
  rm -f "$ZSHRC.bak"
  echo "✓ 已从 $ZSHRC 移除 source 行"
  if grep -qE '\.local/bin' "$ZSHRC"; then
    echo "  ⚠ $ZSHRC 里还有 PATH 包含 ~/.local/bin 的行(可能是本工具加的,也可能你自己有别的命令在那),"
    echo "    若不再需要请手动检查并删除"
  fi
fi

echo ""
echo "✓ 卸载完成"
echo "  注:项目目录里的 .ai-sessions/ 数据**保留**,需要清理自行 rm -rf"
