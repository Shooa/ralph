#!/bin/bash
# Ralph installer — run with: curl -sL https://raw.githubusercontent.com/Shooa/ralph/main/install.sh | bash
set -e

RALPH_HOME="${RALPH_HOME:-$HOME/.ralph}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
REPO="https://github.com/Shooa/ralph"

echo "Installing ralph to $RALPH_HOME..."
mkdir -p "$RALPH_HOME" "$BIN_DIR"

# Download latest from GitHub
curl -sL "$REPO/archive/refs/heads/main.tar.gz" | \
  tar xz -C "$RALPH_HOME" --strip-components=1

# Track version for auto-update
SHA=$(git ls-remote "$REPO.git" HEAD 2>/dev/null | cut -f1 || echo "unknown")
echo "$SHA" > "$RALPH_HOME/.git-sha"

# Symlink binary
ln -sf "$RALPH_HOME/ralph.sh" "$BIN_DIR/ralph"
chmod +x "$RALPH_HOME/ralph.sh"

# Symlink skills to Claude Code
CLAUDE_SKILLS="$HOME/.claude/skills"
mkdir -p "$CLAUDE_SKILLS"
for skill_dir in "$RALPH_HOME"/skills/*/; do
  [ -d "$skill_dir" ] || continue
  skill_name=$(basename "$skill_dir")
  target="$CLAUDE_SKILLS/$skill_name"
  # Remove old symlink
  [ -L "$target" ] && rm "$target"
  # Don't overwrite non-symlink user skills
  [ -e "$target" ] && continue
  ln -s "$skill_dir" "$target"
done

echo ""
echo "Installed:"
echo "  Binary:  $BIN_DIR/ralph -> $RALPH_HOME/ralph.sh"
echo "  Skills:  symlinked to $CLAUDE_SKILLS/"
echo "  Version: $(grep 'RALPH_VERSION=' "$RALPH_HOME/ralph.sh" | head -1 | cut -d'"' -f2)"
echo ""
echo "Usage:"
echo "  cd your-project && ralph --help"
echo ""

# Check if BIN_DIR is in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  echo "WARNING: $BIN_DIR is not in PATH."
  echo "  Add to your shell config:"
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
fi
