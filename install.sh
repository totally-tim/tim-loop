#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing Tim Loop skills..."

mkdir -p ~/.claude/skills ~/.claude/commands

cp -r "$SCRIPT_DIR/skills/tim-loop" ~/.claude/skills/
cp -r "$SCRIPT_DIR/skills/tim-spec" ~/.claude/skills/
cp "$SCRIPT_DIR/commands/tim-loop.md" ~/.claude/commands/
cp "$SCRIPT_DIR/commands/tim-spec.md" ~/.claude/commands/

echo "Installed:"
echo "  ~/.claude/skills/tim-loop/"
echo "  ~/.claude/skills/tim-spec/"
echo "  ~/.claude/commands/tim-loop.md"
echo "  ~/.claude/commands/tim-spec.md"
echo ""
echo "Start a new Claude Code session and use /tim-spec or /tim-loop."
