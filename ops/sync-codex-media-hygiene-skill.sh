#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---dry-run}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$PROJECT_ROOT/ops/skills/codex-media-hygiene"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
TARGET_DIR="$CODEX_HOME/skills/codex-media-hygiene"
BACKUP_ROOT="$CODEX_HOME/skill_backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/codex-media-hygiene-$TIMESTAMP"

usage() {
  cat <<'USAGE'
Usage:
  bash ops/sync-codex-media-hygiene-skill.sh --dry-run
  bash ops/sync-codex-media-hygiene-skill.sh --confirm

Synchronizes the project-managed codex-media-hygiene skill into:
  $CODEX_HOME/skills/codex-media-hygiene

The project copy is the source of truth. --confirm backs up the existing
runtime skill before replacing it.
USAGE
}

if [ "$MODE" = "--help" ] || [ "$MODE" = "-h" ]; then
  usage
  exit 0
fi

if [ "$MODE" != "--dry-run" ] && [ "$MODE" != "--confirm" ]; then
  usage >&2
  exit 2
fi

if [ ! -f "$SOURCE_DIR/SKILL.md" ]; then
  printf 'ERROR: source skill missing: %s\n' "$SOURCE_DIR/SKILL.md" >&2
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  printf 'ERROR: rsync is required for safe directory synchronization.\n' >&2
  exit 1
fi

printf 'Codex media hygiene skill sync\n'
printf 'MODE=%s\n' "$MODE"
printf 'SOURCE_DIR=%s\n' "$SOURCE_DIR"
printf 'TARGET_DIR=%s\n' "$TARGET_DIR"

printf '\nSource files:\n'
find "$SOURCE_DIR" -type f | sort | sed "s#^$SOURCE_DIR/#  #"

if [ "$MODE" = "--dry-run" ]; then
  printf '\nDry-run diff:\n'
  rsync -ain --delete "$SOURCE_DIR/" "$TARGET_DIR/" || true
  printf '\nDry-run actions:\n'
  printf '  Would back up current runtime skill to CODEX_HOME/skill_backups.\n'
  printf '  Would sync project skill to runtime skill directory with rsync --delete.\n'
  exit 0
fi

mkdir -p "$BACKUP_ROOT"
if [ -d "$TARGET_DIR" ]; then
  mkdir -p "$BACKUP_DIR"
  rsync -a "$TARGET_DIR/" "$BACKUP_DIR/"
  printf '\nBacked up existing runtime skill:\n  %s\n' "$BACKUP_DIR"
else
  printf '\nNo existing runtime skill found; creating target directory.\n'
fi

mkdir -p "$TARGET_DIR"
rsync -a --delete "$SOURCE_DIR/" "$TARGET_DIR/"

printf '\nRuntime skill synchronized.\n'
printf 'Verify with:\n'
printf '  diff -qr "%s" "%s"\n' "$SOURCE_DIR" "$TARGET_DIR"
