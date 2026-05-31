#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-health-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

CODEX_HOME="$TMP_DIR/.codex"
mkdir -p "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions" "$TMP_DIR/bin"
printf 'large local log db should not affect health status\n' >"$CODEX_HOME/logs_2.sqlite"
printf 'large local wal should not affect health status\n' >"$CODEX_HOME/logs_2.sqlite-wal"
python3 - "$CODEX_HOME/sessions/rollout-cleaned-large-but-safe.jsonl" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_text('{"type":"event_msg","payload":{"message":"cleaned rollout"}}\n', encoding="utf-8")
Path(sys.argv[1]).open("ab").truncate(60 * 1024 * 1024)
PY

cat >"$TMP_DIR/bin/ps" <<'EOF'
#!/usr/bin/env bash
exit 126
EOF
chmod +x "$TMP_DIR/bin/ps"

output="$(
  CODEX_HOME="$CODEX_HOME" \
  PATH="$TMP_DIR/bin:$PATH" \
  bash "$ROOT/ops/codex-health-check.sh"
)"

printf '%s\n' "$output" | grep -F 'INFO: process check skipped' >/dev/null
printf '%s\n' "$output" | grep -F 'WARN: ps is blocked' >/dev/null && {
  printf 'blocked ps should not produce WARN\n' >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'rollout file exceeds' >/dev/null && {
  printf '60MB cleaned rollout should not exceed the default health-check warning threshold\n' >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'Log database:' >/dev/null && {
  printf 'log database should not be part of health check output\n' >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'logs_2.sqlite + WAL exceed' >/dev/null && {
  printf 'log database size should not produce WARN\n' >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'Result: OK' >/dev/null

printf 'codex health check tests passed\n'
