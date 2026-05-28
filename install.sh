#!/usr/bin/env bash
# Cria symlinks de ~/.claude/ apontando pros arquivos deste repo.
# Idempotente: usa `ln -sf`, sobrescreve symlink existente.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"

mkdir -p "$CLAUDE_DIR/commands" "$CLAUDE_DIR/skills/knowledge-sync" "$CLAUDE_DIR/skills/brain-seed"

link() {
  local src="$1" dst="$2"
  if [[ -e "$dst" && ! -L "$dst" ]]; then
    local bak="${dst}.bak.$(date +%Y-%m-%d-%H%M%S)"
    echo "  ! $dst já existe como arquivo regular — backup em $bak"
    mv "$dst" "$bak"
  fi
  ln -sf "$src" "$dst"
  echo "  ✓ $dst → $src"
}

echo "Instalando symlinks a partir de $REPO_DIR em $CLAUDE_DIR"
link "$REPO_DIR/commands/knowledge-sync-all.md"    "$CLAUDE_DIR/commands/knowledge-sync-all.md"
link "$REPO_DIR/skills/knowledge-sync/SKILL.md"    "$CLAUDE_DIR/skills/knowledge-sync/SKILL.md"
link "$REPO_DIR/skills/brain-seed/SKILL.md"        "$CLAUDE_DIR/skills/brain-seed/SKILL.md"

echo
echo "Pronto. Verifique com: ls -la $CLAUDE_DIR/commands/ $CLAUDE_DIR/skills/*/"
