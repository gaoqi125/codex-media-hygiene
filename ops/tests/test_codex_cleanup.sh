#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-cleanup-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

CODEX_HOME="$TMP_DIR/.codex"
BACKUP_ROOT="$CODEX_HOME/cleanup_backups"
mkdir -p "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions"
mkdir -p "$TMP_DIR/bin"
for day in 01 02 03 04 05 06 07 08 09 10; do
  mkdir -p "$BACKUP_ROOT/202001${day}-000000/sessions"
  mkdir -p "$BACKUP_ROOT/202001${day}-000000/archived_sessions"
done
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_DIR/bin/codex"
chmod +x "$TMP_DIR/bin/codex"

printf 'oldest backup should be pruned\n' >"$BACKUP_ROOT/20200101-000000/sessions/rollout-prune.jsonl"
printf 'recent backup must stay\n' >"$BACKUP_ROOT/20200110-000000/sessions/rollout-keep.jsonl"

invalid_archived_rollout="$CODEX_HOME/archived_sessions/rollout-invalid-image-url.jsonl"
printf '{"type":"response_item","item":{"content":[{"type":"input_image","image_url":"[codex-cleanup media extracted: sha256=abc bytes=123 backup=media_blobs/abc.webp]"}],"text":"archived invalid image text stays"}}\n' >"$invalid_archived_rollout"
invalid_event_images_rollout="$CODEX_HOME/archived_sessions/rollout-invalid-event-images.jsonl"
printf '{"type":"event_msg","payload":{"type":"user_message","message":"archived event image text stays","images":["[codex-cleanup media extracted: sha256=abc bytes=123 backup=media_blobs/abc.webp]"],"local_images":["[codex-cleanup media extracted: sha256=def bytes=456 backup=media_blobs/def.webp]"]}}\n' >"$invalid_event_images_rollout"
invalid_image_generation_rollout="$CODEX_HOME/archived_sessions/rollout-invalid-image-generation.jsonl"
printf '{"type":"response_item","payload":{"type":"image_generation_call","id":"ig_test","status":"generating","result":"[codex-cleanup media extracted: sha256=abc bytes=123 backup=media_blobs/abc.webp]"}}\n' >"$invalid_image_generation_rollout"
media_data_url_rollout="$CODEX_HOME/archived_sessions/rollout-media-data-url.jsonl"
media_data_url_payload="$(printf 'B%.0s' {1..180})"
printf '{"type":"response_item","item":{"content":[{"type":"input_image","image_url":"data:image/jpeg;base64,%s"}],"text":"legal data URL should still be extracted when above media threshold"}}\n' "$media_data_url_payload" >"$media_data_url_rollout"
mcp_media_result_rollout="$CODEX_HOME/archived_sessions/rollout-mcp-media-result.jsonl"
printf '{"type":"event_msg","payload":{"type":"mcp_tool_call_end","call_id":"call_mcp_image","result":{"Ok":{"content":[{"type":"image","mimeType":"image/jpeg","data":"%s"},{"type":"text","text":"mcp text result stays"}]}}}}\n' "$media_data_url_payload" >"$mcp_media_result_rollout"
mcp_default_threshold_rollout="$CODEX_HOME/archived_sessions/rollout-mcp-default-threshold-result.jsonl"
mcp_default_threshold_payload="$(printf 'C%.0s' {1..32768})"
printf '{"type":"event_msg","payload":{"type":"mcp_tool_call_end","call_id":"call_mcp_default_image","result":{"Ok":{"content":[{"type":"image","mimeType":"image/jpeg","data":"%s"}]}}}}\n' "$mcp_default_threshold_payload" >"$mcp_default_threshold_rollout"
recent_session_rollout="$CODEX_HOME/sessions/rollout-recent-session-media.jsonl"
printf '{"type":"response_item","item":{"content":[{"type":"input_image","image_url":"data:image/jpeg;base64,%s"}],"text":"recent session rollout should still use no-restart cleanup"}}\n' "$media_data_url_payload" >"$recent_session_rollout"
backup_invalid_rollout="$BACKUP_ROOT/20200110-000000/archived_sessions/rollout-backup-invalid-image-generation.jsonl"
printf '{"type":"response_item","payload":{"type":"image_generation_call","id":"ig_backup","status":"generating","result":"[codex-cleanup media extracted: sha256=backup bytes=123 backup=media_blobs/backup.webp]"}}\n' >"$backup_invalid_rollout"

invalid_dry_run="$(
  CODEX_HOME="$CODEX_HOME" \
  PATH="$TMP_DIR/bin:$PATH" \
  WARN_ROLLOUT_LINE_BYTES=1000000 \
  CODEX_MEDIA_DATA_URL_MIN_BYTES=100 \
  bash "$ROOT/ops/codex-cleanup.sh" --dry-run
)"

printf '%s\n' "$invalid_dry_run" | grep -F "Rollout files with invalid input_image image_url:" >/dev/null || {
  printf 'dry run should report invalid input_image image_url files\n' >&2
  exit 1
}

printf '%s\n' "$invalid_dry_run" | grep -F "$invalid_archived_rollout" >/dev/null || {
  printf 'dry run should include archived rollout with invalid image_url even when not oversized\n' >&2
  exit 1
}

printf '%s\n' "$invalid_dry_run" | grep -F "$invalid_event_images_rollout" >/dev/null || {
  printf 'dry run should include archived rollout with invalid event images even when not oversized\n' >&2
  exit 1
}

printf '%s\n' "$invalid_dry_run" | grep -F "$invalid_image_generation_rollout" >/dev/null || {
  printf 'dry run should include archived rollout with invalid image generation result even when not oversized\n' >&2
  exit 1
}

printf '%s\n' "$invalid_dry_run" | grep -F "$media_data_url_rollout" >/dev/null || {
  printf 'dry run should include rollout with legal media data URL above media threshold even when not oversized\n' >&2
  exit 1
}

printf '%s\n' "$invalid_dry_run" | grep -F "Rollout files with MCP media result data over 100 encoded bytes:" >/dev/null || {
  printf 'dry run should report MCP media result data files\n' >&2
  exit 1
}

printf '%s\n' "$invalid_dry_run" | grep -F "$mcp_media_result_rollout" >/dev/null || {
  printf 'dry run should include rollout with MCP media result data above threshold even when not oversized\n' >&2
  exit 1
}

printf '%s\n' "$invalid_dry_run" | grep -F "$recent_session_rollout" >/dev/null || {
  printf 'dry run should include recent session rollout instead of skipping it as active\n' >&2
  exit 1
}

printf '%s\n' "$invalid_dry_run" | grep -F 'Recent active risky rollout files skipped' >/dev/null && {
  printf 'dry run should not have an active-rollout skip section\n' >&2
  exit 1
}

printf '%s\n' "$invalid_dry_run" | grep -F 'Would not distinguish active and inactive rollouts' >/dev/null || {
  printf 'dry run should state active and inactive rollouts use the same no-restart cleanup path\n' >&2
  exit 1
}

printf '%s\n' "$invalid_dry_run" | grep -F "$backup_invalid_rollout" >/dev/null && {
  printf 'dry run should skip rollout files under cleanup_backups\n' >&2
  exit 1
}

printf '%s\n' "$invalid_dry_run" | grep -F "Would skip cleanup_backups rollout files during media scrubbing" >/dev/null || {
  printf 'dry run should state that cleanup_backups rollout files are skipped during media scrubbing\n' >&2
  exit 1
}

rollout="$CODEX_HOME/sessions/rollout-media.jsonl"
media_payload="$(printf 'A%.0s' {1..180})"
printf '{"type":"response_item","item":{"content":[{"type":"input_image","image_url":"data:image/jpeg;base64,%s"}],"text":"keep this conversation text"}}\n' "$media_payload" >"$rollout"
printf '{"type":"response_item","item":{"content":[{"type":"input_image","image_url":"data:image/png;base64,AAAAA"}],"text":"keep invalid media text"}}\n' >>"$rollout"
printf '{"type":"event_msg","payload":{"type":"user_message","message":"image placeholders should become text only","images":["[codex-cleanup media extracted: sha256=abc bytes=123 backup=media_blobs/abc.webp]"],"local_images":["[codex-cleanup media extracted: sha256=def bytes=456 backup=media_blobs/def.webp]"],"text_elements":[]}}\n' >>"$rollout"
printf '{"type":"event_msg","payload":{"type":"image_generation_end","status":"generating","result":"data:image/png;base64,%s","saved_path":"/tmp/generated.png"}}\n' "$media_payload" >>"$rollout"
printf '{"type":"response_item","payload":{"type":"image_generation_call","id":"ig_test","status":"generating","result":"data:image/png;base64,%s"}}\n' "$media_payload" >>"$rollout"
printf '{"type":["unexpected","list"],"result":"data:image/png;base64,%s","text":"type list should not crash scrubber"}\n' "$media_payload" >>"$rollout"

CODEX_HOME="$CODEX_HOME" \
PATH="$TMP_DIR/bin:$PATH" \
WARN_ROLLOUT_LINE_BYTES=100 \
CODEX_MEDIA_DATA_URL_MIN_BYTES=100 \
bash "$ROOT/ops/codex-cleanup.sh" --confirm >/dev/null

[ -f "$rollout" ] || {
  printf 'rollout should remain at its original path after media cleanup\n' >&2
  exit 1
}

grep -F 'keep this conversation text' "$rollout" >/dev/null || {
  printf 'conversation text should be preserved after media cleanup\n' >&2
  exit 1
}

grep -F 'keep invalid media text' "$rollout" >/dev/null || {
  printf 'conversation text near invalid media should be preserved after media cleanup\n' >&2
  exit 1
}

grep -F 'data:image/jpeg;base64,' "$rollout" >/dev/null && {
  printf 'base64 media payload should be scrubbed from rollout\n' >&2
  exit 1
}

python3 - "$rollout" <<'PY'
import json
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    item = json.loads(line)

    def walk(value):
        if isinstance(value, dict):
            if value.get("type") == "input_image":
                raise SystemExit("scrubbed media should not remain as input_image")
            if "image_url" in value and str(value["image_url"]).startswith("[codex-cleanup"):
                raise SystemExit("scrubbed placeholder should not remain in image_url")
            if isinstance(value.get("images"), list) and any(
                isinstance(image, str) and image.startswith("[codex-cleanup")
                for image in value["images"]
            ):
                raise SystemExit("scrubbed placeholder should not remain in event images")
            if isinstance(value.get("local_images"), list) and any(
                isinstance(image, str) and image.startswith("[codex-cleanup")
                for image in value["local_images"]
            ):
                raise SystemExit("scrubbed placeholder should not remain in event local_images")
            value_type = value.get("type")
            if isinstance(value_type, str) and value_type in {"image_generation_call", "image_generation_end"} and str(
                value.get("result", "")
            ).startswith("[codex-cleanup"):
                raise SystemExit("scrubbed placeholder should not remain in image generation result")
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(item)
PY

find "$BACKUP_ROOT" -path '*/original_rollouts/sessions/rollout-media.jsonl' -type f | grep . >/dev/null || {
  printf 'original rollout backup should be retained before scrubbing\n' >&2
  exit 1
}

find "$BACKUP_ROOT" -path '*/media_blobs/*' -type f | grep . >/dev/null || {
  printf 'scrubbed media payload should be written to media_blobs backup\n' >&2
  exit 1
}

grep -F 'sha256=backup' "$backup_invalid_rollout" >/dev/null || {
  printf 'cleanup_backups rollout files should remain untouched by confirmed cleanup\n' >&2
  exit 1
}

grep -F 'data:image/jpeg;base64,' "$media_data_url_rollout" >/dev/null && {
  printf 'legal media data URL above threshold should be scrubbed from archived rollout\n' >&2
  exit 1
}

python3 - "$mcp_media_result_rollout" <<'PY'
import json
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    item = json.loads(line)

    def walk(value):
        if isinstance(value, dict):
            value_type = value.get("type")
            if (
                isinstance(value_type, str)
                and value_type in {"image", "audio", "video"}
                and isinstance(value.get("data"), str)
            ):
                raise SystemExit("MCP media result data should be scrubbed from rollout")
            if value.get("type") == "text" and str(value.get("text", "")).startswith("[codex-cleanup media extracted:"):
                return
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(item)
PY

CODEX_HOME="$CODEX_HOME" \
PATH="$TMP_DIR/bin:$PATH" \
WARN_ROLLOUT_LINE_BYTES=1000000 \
CODEX_MEDIA_DATA_URL_MIN_BYTES=32768 \
bash "$ROOT/ops/codex-cleanup.sh" --confirm >/dev/null

python3 - "$mcp_default_threshold_rollout" <<'PY'
import json
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    item = json.loads(line)

    def walk(value):
        if isinstance(value, dict):
            if value.get("type") == "image" and isinstance(value.get("data"), str):
                raise SystemExit("MCP media result data at the default media threshold should be scrubbed")
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(item)
PY

mcp_default_env_rollout="$CODEX_HOME/archived_sessions/rollout-mcp-default-env-result.jsonl"
printf '{"type":"event_msg","payload":{"type":"mcp_tool_call_end","call_id":"call_mcp_default_env_image","result":{"Ok":{"content":[{"type":"image","mimeType":"image/jpeg","data":"%s"}]}}}}\n' "$mcp_default_threshold_payload" >"$mcp_default_env_rollout"

CODEX_HOME="$CODEX_HOME" \
PATH="$TMP_DIR/bin:$PATH" \
WARN_ROLLOUT_LINE_BYTES=1000000 \
bash "$ROOT/ops/codex-cleanup.sh" --confirm >/dev/null

python3 - "$mcp_default_env_rollout" <<'PY'
import json
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    item = json.loads(line)

    def walk(value):
        if isinstance(value, dict):
            if value.get("type") == "image" and isinstance(value.get("data"), str):
                raise SystemExit("MCP media result data should use the cleanup script default media threshold")
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(item)
PY

grep -F 'data:image/jpeg;base64,' "$recent_session_rollout" >/dev/null && {
  printf 'recent session rollout should be scrubbed by normal no-restart cleanup\n' >&2
  exit 1
}

backup_count="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[ "$backup_count" = "10" ] || {
  printf 'confirmed cleanup should keep only the latest 10 backup directories, got %s\n' "$backup_count" >&2
  exit 1
}

[ ! -e "$BACKUP_ROOT/20200101-000000" ] || {
  printf 'confirmed cleanup should prune the oldest backup directory\n' >&2
  exit 1
}

[ -e "$BACKUP_ROOT/20200110-000000" ] || {
  printf 'confirmed cleanup should retain recent backup directories\n' >&2
  exit 1
}

for removed_script in \
  "$ROOT/ops/codex-maintenance-window.sh" \
  "$ROOT/ops/codex-launch-maintenance-window.sh" \
  "$ROOT/ops/codex-launch-cleanup.sh"
do
  if [ -e "$removed_script" ]; then
    printf 'deprecated media cleanup entrypoint should be removed: %s\n' "$removed_script" >&2
    exit 1
  fi
done

skill_sync_home="$TMP_DIR/skill-sync/.codex"
mkdir -p "$skill_sync_home/skills/codex-media-hygiene"
printf 'stale runtime copy\n' >"$skill_sync_home/skills/codex-media-hygiene/stale.txt"

sync_dry_run="$(
  CODEX_HOME="$skill_sync_home" \
  bash "$ROOT/ops/sync-codex-media-hygiene-skill.sh" --dry-run
)"

printf '%s\n' "$sync_dry_run" | grep -F 'Would sync project skill to runtime skill directory' >/dev/null || {
  printf 'skill sync dry-run should explain the pending runtime update\n' >&2
  exit 1
}

CODEX_HOME="$skill_sync_home" \
bash "$ROOT/ops/sync-codex-media-hygiene-skill.sh" --confirm >/dev/null

diff -qr "$ROOT/ops/skills/codex-media-hygiene" "$skill_sync_home/skills/codex-media-hygiene" >/dev/null || {
  printf 'confirmed skill sync should make runtime skill match project source\n' >&2
  exit 1
}

find "$skill_sync_home/skill_backups" -type f -name 'stale.txt' | grep . >/dev/null || {
  printf 'skill sync should back up existing runtime skill before replacing it\n' >&2
  exit 1
}

if [ -e "$ROOT/ops/skills/codex-media-hygiene/references/media-field-policy.md" ]; then
  printf 'media hygiene policy should not be split into references/media-field-policy.md\n' >&2
  exit 1
fi

grep -F 'This SKILL.md is the only maintained policy source' "$ROOT/ops/skills/codex-media-hygiene/SKILL.md" >/dev/null || {
  printf 'media hygiene skill should declare SKILL.md as the single maintained policy document\n' >&2
  exit 1
}

grep -F 'input_image.image_url' "$ROOT/ops/skills/codex-media-hygiene/SKILL.md" >/dev/null || {
  printf 'media hygiene skill should keep structured media field policy inline\n' >&2
  exit 1
}

grep -F 'mcp_tool_call_end.result.Ok.content[].data' "$ROOT/ops/skills/codex-media-hygiene/SKILL.md" >/dev/null || {
  printf 'media hygiene skill should document MCP media result data cleanup\n' >&2
  exit 1
}

grep -F 'keeping the latest 10 backups by default' "$ROOT/ops/skills/codex-media-hygiene/SKILL.md" >/dev/null || {
  printf 'media hygiene skill should document backup retention\n' >&2
  exit 1
}

printf 'codex cleanup tests passed\n'
