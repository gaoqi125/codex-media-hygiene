#!/usr/bin/env bash
set -uo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
CONTROL_DIR="$CODEX_HOME/app-server-control"
LOCK_DIR="$CONTROL_DIR/cleanup.lock"
STATUS_FILE="$CONTROL_DIR/cleanup-status.txt"
WARN_SESSION_MB="${WARN_SESSION_MB:-50}"
WARN_ROLLOUT_LINE_BYTES="${WARN_ROLLOUT_LINE_BYTES:-1048576}"
MEDIA_DATA_URL_MIN_BYTES="${CODEX_MEDIA_DATA_URL_MIN_BYTES:-32768}"
BACKUP_ROOT="${BACKUP_ROOT:-$CODEX_HOME/cleanup_backups}"
BACKUP_KEEP="${CODEX_CLEANUP_BACKUP_KEEP:-10}"
MODE="${1:---dry-run}"
backup_dir=""

usage() {
  cat <<'EOF'
Usage:
  bash ops/codex-cleanup.sh --dry-run
  bash ops/codex-cleanup.sh --confirm

Behavior:
  --dry-run   Show what would be scrubbed.
  --confirm   Back up rollout files and scrub embedded media payloads in place.

Retention:
  Rollout JSONL files containing a single record over WARN_ROLLOUT_LINE_BYTES are scrubbed
  only when embedded image/video/audio Base64 payloads are found. Rollout JSONL files
  containing image/video/audio data URLs over CODEX_MEDIA_DATA_URL_MIN_BYTES are also
  scrubbed. Real sessions and archived sessions are backed up under BACKUP_DIR/original_rollouts before scrubbing.
  Existing cleanup_backups rollout files are skipped during media scrubbing. After
  a successful confirmed cleanup, old backup directories are pruned by retention.
  Extracted media goes under BACKUP_DIR/media_blobs, and rollout files remain at their
  original paths so old conversations can still resolve.
  Cleanup does not distinguish active and inactive rollouts. Confirmed cleanup
  backs up the original rollout, scrubs embedded media in place, and does not
  restart app-server/proxy.
  Confirmed cleanup prunes old backup directories after a successful run and keeps
  the latest CODEX_CLEANUP_BACKUP_KEEP directories, defaulting to 10.
EOF
}

write_status() {
  local status="$1"
  local note="${2:-}"
  umask 077
  mkdir -p "$CONTROL_DIR"
  {
    printf 'timestamp=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'status=%s\n' "$status"
    printf 'backup_dir=%s\n' "$backup_dir"
    [ -n "$note" ] && printf 'note=%s\n' "$note"
  } >"$STATUS_FILE"
}

cleanup_once() {
  local status="$?"
  if [ "$MODE" = "--confirm" ]; then
    if [ "$status" -ne 0 ]; then
      write_status "failed" "cleanup exited with status $status; not retrying automatically"
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  exit "$status"
}

trap cleanup_once EXIT

has_oversized_record() {
  awk -v warn="$WARN_ROLLOUT_LINE_BYTES" '
    length($0) > warn {
      found = 1
      exit
    }
    END {
      exit found ? 0 : 1
    }
  ' "$1"
}

has_media_data_url() {
  python3 - "$1" "$MEDIA_DATA_URL_MIN_BYTES" <<'PY'
import json
import re
import sys
from pathlib import Path


DATA_URL_RE = re.compile(
    r"data:(?:image|video|audio)/[A-Za-z0-9.+-]+;base64,([A-Za-z0-9+/=\r\n]+)"
)


def has_media(value, min_bytes: int) -> bool:
    if isinstance(value, str):
        for match in DATA_URL_RE.finditer(value):
            if len("".join(match.group(1).split())) >= min_bytes:
                return True
        return False
    if isinstance(value, dict):
        return any(has_media(child, min_bytes) for child in value.values())
    if isinstance(value, list):
        return any(has_media(child, min_bytes) for child in value)
    return False


path = Path(sys.argv[1])
min_bytes = int(sys.argv[2])
try:
    with path.open("r", encoding="utf-8", errors="replace") as source:
        for line in source:
            try:
                parsed = json.loads(line)
            except json.JSONDecodeError:
                if has_media(line, min_bytes):
                    raise SystemExit(0)
                continue
            if has_media(parsed, min_bytes):
                raise SystemExit(0)
except OSError:
    pass

raise SystemExit(1)
PY
}

has_mcp_media_result_data() {
  python3 - "$1" "$MEDIA_DATA_URL_MIN_BYTES" <<'PY'
import json
import re
import sys
from pathlib import Path


MEDIA_TYPES = {"image", "video", "audio"}
BASE64_RE = re.compile(r"^[A-Za-z0-9+/]+={0,2}$")


def looks_like_base64(value: str, min_bytes: int) -> bool:
    compact = "".join(value.split())
    if len(compact) < min_bytes or len(compact) % 4 != 0:
        return False
    return BASE64_RE.fullmatch(compact) is not None


def has_mcp_media(value, min_bytes: int) -> bool:
    if isinstance(value, dict):
        value_type = value.get("type")
        mime = value.get("mimeType")
        data = value.get("data")
        if (
            isinstance(value_type, str)
            and value_type in MEDIA_TYPES
            and isinstance(mime, str)
            and mime.split("/", 1)[0] in MEDIA_TYPES
            and isinstance(data, str)
            and looks_like_base64(data, min_bytes)
        ):
            return True
        return any(has_mcp_media(child, min_bytes) for child in value.values())
    if isinstance(value, list):
        return any(has_mcp_media(child, min_bytes) for child in value)
    return False


path = Path(sys.argv[1])
min_bytes = int(sys.argv[2])
try:
    with path.open("r", encoding="utf-8", errors="replace") as source:
        for line in source:
            try:
                parsed = json.loads(line)
            except json.JSONDecodeError:
                continue
            if has_mcp_media(parsed, min_bytes):
                raise SystemExit(0)
except OSError:
    pass

raise SystemExit(1)
PY
}

has_invalid_input_image_url() {
  python3 - "$1" <<'PY'
import json
import sys
from pathlib import Path


def has_bad_image_url(value) -> bool:
    if isinstance(value, dict):
        if value.get("type") == "input_image" and "image_url" in value:
            image_url = value.get("image_url")
            if not (
                isinstance(image_url, str)
                and (
                    image_url.startswith("http://")
                    or image_url.startswith("https://")
                    or image_url.startswith("data:image/")
                )
            ):
                return True
        return any(has_bad_image_url(child) for child in value.values())
    if isinstance(value, list):
        return any(has_bad_image_url(child) for child in value)
    return False


path = Path(sys.argv[1])
try:
    with path.open("r", encoding="utf-8", errors="replace") as source:
        for line in source:
            try:
                parsed = json.loads(line)
            except json.JSONDecodeError:
                continue
            if has_bad_image_url(parsed):
                raise SystemExit(0)
except OSError:
    pass

raise SystemExit(1)
PY
}

has_invalid_event_image_refs() {
  python3 - "$1" <<'PY'
import json
import sys
from pathlib import Path


PLACEHOLDER_PREFIX = "[codex-cleanup media extracted:"


def has_bad_event_image_ref(value) -> bool:
    if isinstance(value, dict):
        for key in ("images", "local_images"):
            image_refs = value.get(key)
            if isinstance(image_refs, list) and any(
                isinstance(image_ref, str) and image_ref.startswith(PLACEHOLDER_PREFIX)
                for image_ref in image_refs
            ):
                return True
        return any(has_bad_event_image_ref(child) for child in value.values())
    if isinstance(value, list):
        return any(has_bad_event_image_ref(child) for child in value)
    return False


path = Path(sys.argv[1])
try:
    with path.open("r", encoding="utf-8", errors="replace") as source:
        for line in source:
            try:
                parsed = json.loads(line)
            except json.JSONDecodeError:
                continue
            if has_bad_event_image_ref(parsed):
                raise SystemExit(0)
except OSError:
    pass

raise SystemExit(1)
PY
}

has_invalid_image_generation_result() {
  python3 - "$1" <<'PY'
import json
import sys
from pathlib import Path


PLACEHOLDER_PREFIX = "[codex-cleanup media extracted:"


def has_bad_image_generation_result(value) -> bool:
    if isinstance(value, dict):
        value_type = value.get("type")
        if isinstance(value_type, str) and value_type in {"image_generation_call", "image_generation_end"}:
            result = value.get("result")
            if isinstance(result, str) and result.startswith(PLACEHOLDER_PREFIX):
                return True
        return any(has_bad_image_generation_result(child) for child in value.values())
    if isinstance(value, list):
        return any(has_bad_image_generation_result(child) for child in value)
    return False


path = Path(sys.argv[1])
try:
    with path.open("r", encoding="utf-8", errors="replace") as source:
        for line in source:
            try:
                parsed = json.loads(line)
            except json.JSONDecodeError:
                continue
            if has_bad_image_generation_result(parsed):
                raise SystemExit(0)
except OSError:
    pass

raise SystemExit(1)
PY
}

prune_old_backups() {
  if ! [[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] || [ "$BACKUP_KEEP" -lt 1 ]; then
    printf 'ERROR: CODEX_CLEANUP_BACKUP_KEEP must be a positive integer: %s\n' "$BACKUP_KEEP" >&2
    return 1
  fi

  [ -d "$BACKUP_ROOT" ] || return 0

  local count
  count="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | wc -l | tr -d ' ')"
  local prune_count=$((count - BACKUP_KEEP))
  if [ "$prune_count" -le 0 ]; then
    printf '\nBackup retention: %s backup director%s present; keeping latest %s.\n' \
      "$count" "$([ "$count" = "1" ] && printf 'y' || printf 'ies')" "$BACKUP_KEEP"
    return 0
  fi

  printf '\nPruning old cleanup backup directories, keeping latest %s:\n' "$BACKUP_KEEP"
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null |
    sort |
    awk -v limit="$prune_count" 'NR <= limit { print }' |
    while IFS= read -r old_backup; do
      printf '  %s\n' "$old_backup"
      rm -rf "$old_backup"
    done
}

if [ "$MODE" != "--dry-run" ] && [ "$MODE" != "--confirm" ]; then
  usage
  exit 64
fi

if [ ! -d "$CODEX_HOME" ]; then
  printf 'ERROR: CODEX_HOME does not exist: %s\n' "$CODEX_HOME" >&2
  exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$BACKUP_ROOT/$timestamp"
sessions_dir="$CODEX_HOME/sessions"
archived_dir="$CODEX_HOME/archived_sessions"

printf 'Codex cleanup\n'
printf 'MODE=%s\n' "$MODE"
printf 'CODEX_HOME=%s\n' "$CODEX_HOME"
printf 'CODEX_MEDIA_DATA_URL_MIN_BYTES=%s\n' "$MEDIA_DATA_URL_MIN_BYTES"
printf 'CODEX_CLEANUP_BACKUP_KEEP=%s\n' "$BACKUP_KEEP"
printf 'BACKUP_DIR=%s\n\n' "$backup_dir"

if [ "$MODE" = "--confirm" ]; then
  mkdir -p "$CONTROL_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    write_status "skipped" "another cleanup is already running"
    printf 'Another cleanup is already running; skipped this run.\n'
    exit 0
  fi
  write_status "started" "cleanup started"
fi

collect_large_files() {
  find "$sessions_dir" "$archived_dir" \
    -type f -name 'rollout-*.jsonl' \
    ! -path '*/original_rollouts/*' \
    -size +"${WARN_SESSION_MB}"M -print 2>/dev/null
}

collect_oversized_record_files() {
  find "$sessions_dir" "$archived_dir" \
    -type f -name 'rollout-*.jsonl' \
    ! -path '*/original_rollouts/*' -print 2>/dev/null |
    while IFS= read -r file; do
      if has_oversized_record "$file"; then
        printf '%s\n' "$file"
      fi
    done
}

collect_media_data_url_files() {
  find "$sessions_dir" "$archived_dir" \
    -type f -name 'rollout-*.jsonl' \
    ! -path '*/original_rollouts/*' -print 2>/dev/null |
    while IFS= read -r file; do
      if has_media_data_url "$file"; then
        printf '%s\n' "$file"
      fi
    done
}

collect_mcp_media_result_data_files() {
  find "$sessions_dir" "$archived_dir" \
    -type f -name 'rollout-*.jsonl' \
    ! -path '*/original_rollouts/*' -print 2>/dev/null |
    while IFS= read -r file; do
      if has_mcp_media_result_data "$file"; then
        printf '%s\n' "$file"
      fi
    done
}

collect_invalid_input_image_url_files() {
  find "$sessions_dir" "$archived_dir" \
    -type f -name 'rollout-*.jsonl' \
    ! -path '*/original_rollouts/*' -print 2>/dev/null |
    while IFS= read -r file; do
      if has_invalid_input_image_url "$file"; then
        printf '%s\n' "$file"
      fi
    done
}

collect_invalid_event_image_ref_files() {
  find "$sessions_dir" "$archived_dir" \
    -type f -name 'rollout-*.jsonl' \
    ! -path '*/original_rollouts/*' -print 2>/dev/null |
    while IFS= read -r file; do
      if has_invalid_event_image_refs "$file"; then
        printf '%s\n' "$file"
      fi
    done
}

collect_invalid_image_generation_result_files() {
  find "$sessions_dir" "$archived_dir" \
    -type f -name 'rollout-*.jsonl' \
    ! -path '*/original_rollouts/*' -print 2>/dev/null |
    while IFS= read -r file; do
      if has_invalid_image_generation_result "$file"; then
        printf '%s\n' "$file"
      fi
    done
}

large_files="$(collect_large_files)"
oversized_record_files="$(collect_oversized_record_files)"
media_data_url_files="$(collect_media_data_url_files)"
mcp_media_result_data_files="$(collect_mcp_media_result_data_files)"
invalid_input_image_url_files="$(collect_invalid_input_image_url_files)"
invalid_event_image_ref_files="$(collect_invalid_event_image_ref_files)"
invalid_image_generation_result_files="$(collect_invalid_image_generation_result_files)"
files_to_scrub="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$large_files" "$oversized_record_files" "$media_data_url_files" "$mcp_media_result_data_files" "$invalid_input_image_url_files" "$invalid_event_image_ref_files" "$invalid_image_generation_result_files" | awk 'NF' | sort -u)"

printf 'Large rollout files over %s MB:\n' "$WARN_SESSION_MB"
if [ -n "$large_files" ]; then
  printf '%s\n' "$large_files" | while IFS= read -r file; do
    size="$(du -h "$file" 2>/dev/null | awk '{print $1}')"
    printf '  %7s  %s\n' "$size" "$file"
  done
else
  printf '  none\n'
fi

printf '\nRollout files with records over %s bytes:\n' "$WARN_ROLLOUT_LINE_BYTES"
if [ -n "$oversized_record_files" ]; then
  printf '%s\n' "$oversized_record_files" | sort -u | while IFS= read -r file; do
    summary="$(awk -v warn="$WARN_ROLLOUT_LINE_BYTES" '
      length($0) > warn {
        count += 1
        if (length($0) > max_len) {
          max_len = length($0)
        }
      }
      END {
        printf "%s oversized line(s), max=%s bytes", count, max_len
      }
    ' "$file")"
    printf '  %s  %s\n' "$summary" "$file"
  done
else
  printf '  none\n'
fi

printf '\nRollout files with media data URLs over %s encoded bytes:\n' "$MEDIA_DATA_URL_MIN_BYTES"
if [ -n "$media_data_url_files" ]; then
  printf '%s\n' "$media_data_url_files" | sort -u | while IFS= read -r file; do
    printf '  %s\n' "$file"
  done
else
  printf '  none\n'
fi

printf '\nRollout files with MCP media result data over %s encoded bytes:\n' "$MEDIA_DATA_URL_MIN_BYTES"
if [ -n "$mcp_media_result_data_files" ]; then
  printf '%s\n' "$mcp_media_result_data_files" | sort -u | while IFS= read -r file; do
    printf '  %s\n' "$file"
  done
else
  printf '  none\n'
fi

printf '\nRollout files with invalid input_image image_url:\n'
if [ -n "$invalid_input_image_url_files" ]; then
  printf '%s\n' "$invalid_input_image_url_files" | sort -u | while IFS= read -r file; do
    printf '  %s\n' "$file"
  done
else
  printf '  none\n'
fi

printf '\nRollout files with invalid event images/local_images refs:\n'
if [ -n "$invalid_event_image_ref_files" ]; then
  printf '%s\n' "$invalid_event_image_ref_files" | sort -u | while IFS= read -r file; do
    printf '  %s\n' "$file"
  done
else
  printf '  none\n'
fi

printf '\nRollout files with invalid image_generation result refs:\n'
if [ -n "$invalid_image_generation_result_files" ]; then
  printf '%s\n' "$invalid_image_generation_result_files" | sort -u | while IFS= read -r file; do
    printf '  %s\n' "$file"
  done
else
  printf '  none\n'
fi

if [ "$MODE" = "--dry-run" ]; then
  printf '\nDry run actions:\n'
  printf '  Would back up real sessions/archived_sessions rollout files into BACKUP_DIR/original_rollouts.\n'
  printf '  Would skip cleanup_backups rollout files during media scrubbing.\n'
  printf '  Would scrub embedded media Base64 in place and store extracted blobs in BACKUP_DIR/media_blobs.\n'
  printf '  Would not distinguish active and inactive rollouts, and would not restart app-server/proxy.\n'
  printf '  Would keep rollout files at their original paths so old conversations can still resolve.\n'
  printf '  Would prune old cleanup backup directories after a successful confirmed cleanup, keeping latest %s.\n' "$BACKUP_KEEP"
  exit 0
fi

mkdir -p "$backup_dir"

if [ -n "$files_to_scrub" ]; then
  printf '\nScrubbing embedded media from rollout files:\n'
  scrub_failed=0
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    printf '  %s\n' "$file"
    if ! CODEX_SCRUB_PRESERVE_ORIGINAL=1 CODEX_MEDIA_DATA_URL_MIN_BYTES="$MEDIA_DATA_URL_MIN_BYTES" python3 "$PROJECT_ROOT/ops/codex-scrub-rollout-media.py" \
      "$file" "$backup_dir" "$CODEX_HOME" "$WARN_ROLLOUT_LINE_BYTES" |
      sed 's/^/    /'; then
      scrub_failed=1
    fi
  done <<< "$files_to_scrub"
  if [ "$scrub_failed" -ne 0 ]; then
    write_status "failed" "one or more rollout media scrub operations failed"
    printf '\nERROR: one or more rollout media scrub operations failed.\n' >&2
    exit 1
  fi
else
  printf '\nNo risky rollout files to scrub.\n'
fi

prune_old_backups

printf '\nCleanup completed.\n'
write_status "completed" "cleanup completed"
