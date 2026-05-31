---
name: codex-media-hygiene
description: Diagnose Codex App/CLI media-related rollout problems and guide consent-based cleanup. Use when Codex conversations hang, restore fails, stream disconnects after image use, cleanup touches ~/.codex, large Base64/image/video/audio payloads appear in rollout JSONL, Image2/image_generation/view_image/dragged or pasted images cause invalid image errors, or when maintaining ops/codex-cleanup.sh, ops/codex-health-check.sh, or ops/codex-scrub-rollout-media.py. Ask the user before running cleanup actions.
---

# Codex Media Hygiene

## Purpose

Protect Codex conversations from media payload bloat and invalid structured image fields while preserving old conversation paths and text. Treat this as a safety workflow: diagnose from rollout JSONL structure, avoid printing Base64, ask for consent before cleanup, run dry-run before confirmed cleanup, scrub risky rollout files in place after backing them up, and verify after every change.

This SKILL.md is the only maintained policy source for Codex media hygiene. Keep `AGENTS.md` and project docs as entrypoints only; do not copy cleanup rules there. This skill is on-demand: use it when the user asks for Codex cleanup/recovery, or when a current conversation image may require a one-time cleanup reminder. Do not run routine health checks just because a task step finished. Edit the project source in `ops/skills/codex-media-hygiene/`, then run `bash ops/sync-codex-media-hygiene-skill.sh --dry-run` and `bash ops/sync-codex-media-hygiene-skill.sh --confirm` to update `$CODEX_HOME/skills/codex-media-hygiene/`.

## Core Workflow

1. Confirm the target session and current state.
   - Find active conversation rollout files by session id under `$CODEX_HOME/sessions` and archived conversation rollouts under `$CODEX_HOME/archived_sessions`.
   - Treat `$CODEX_HOME/cleanup_backups` as rollback material: inspect it only when debugging a failed cleanup or manual restore, and skip its contents during media scrubbing.
   - Run the project health check when available: `bash ops/codex-health-check.sh`.
   - Do not paste or print Base64/media contents; report paths, line numbers, field names, byte lengths, and value categories only.

2. Classify the problem before fixing.
   - Restore path missing: check whether the rollout file exists at the exact path.
   - Invalid image URL: inspect `input_image.image_url` and structured image references.
   - Image2/Image generation failure: inspect `image_generation_call` and `image_generation_end`, especially `result` and `saved_path`.
   - Computer Use / MCP screenshot bloat: inspect `mcp_tool_call_end.result.Ok.content[]`, especially image/audio/video entries with raw `data`.
   - App slowdown: inspect large rollout lines, large session files, and app-server/proxy process state.

3. Ask before cleanup.
   - Image2, `view_image`, dragged/pasted images, and Codex image generation are allowed in normal work. Do not block them just because they may add media to rollout history.
   - Do not mention this skill during routine work. Give a one-time reminder only after the current conversation writes image media into context, or when the user explicitly asks for cleanup/recovery help.
   - Do not automatically run `ops/codex-cleanup.sh --confirm` just because this skill was triggered.
   - It is acceptable to run read-only checks such as `bash ops/codex-health-check.sh` and `bash ops/codex-cleanup.sh --dry-run` when diagnosing.
   - Default to dry-run first. Use the dry-run output to classify each risky rollout before choosing an action.
   - Do not distinguish active and inactive rollouts for the cleanup decision. If a real `sessions` or `archived_sessions` rollout is risky, confirmed cleanup should back it up and scrub embedded media in place.
   - Confirmed cleanup is media-only by default and must not restart app-server/proxy.
   - Confirmed cleanup prunes old `$CODEX_HOME/cleanup_backups` directories only after a successful run, keeping the latest 10 backups by default. Override only with `CODEX_CLEANUP_BACKUP_KEEP`.
   - Restart and detached-launch cleanup wrappers are not part of the maintained workflow. If Codex itself is unusable, ask the user to restart Codex manually, then verify with the health check after recovery.

4. Scrub media by structure, not by one-off field patches.
   - Follow the structured media policy below.
   - A cleanup placeholder is safe in plain text, command output, or notes; it is unsafe inside fields that Codex later treats as media.
   - When adding new logic, add both a detector and a post-clean validator.

5. Verify after cleanup or maintenance.
   - Re-run `bash ops/codex-health-check.sh`.
   - Re-scan current and archived rollouts for invalid structured media references.
   - Confirm target rollout JSON parses cleanly and the problematic fields are absent or converted to safe text.

## Safety Rules

- Treat any old rule that directly runs cleanup after a task step as deprecated; the entrypoint is now to ask whether to invoke `$codex-media-hygiene`.
- Ask for explicit user confirmation before destructive, rewriting, cleanup, or app-server restart actions.
- Active and inactive rollout files use the same media-only cleanup path: back up the original, scrub embedded media in place, preserve the rollout path, and do not restart app-server/proxy.
- Do not run any maintained media cleanup command that restarts app-server. Manual app restarts are user-controlled recovery steps, not part of this skill's cleanup flow.
- Do not delete rollout files to solve media bloat. Preserve original paths so old conversations can resolve.
- Back up real `sessions` and `archived_sessions` rollout files before in-place scrubbing.
- Do not scrub or rewrite old `cleanup_backups` rollout files. Confirmed cleanup may delete whole old backup directories only through the documented retention policy, defaulting to the latest 10 backups.
- Do not restore Base64 into a long-running conversation as a fix.
- Do not suggest OpenAI API `file_id` for this user unless they explicitly switch from ChatGPT Pro to API billing.
- For local images, use the tool that fits the task: local paths, `view_image`, drag/paste, Image2/image generation, `sips`, `ffprobe`, metadata scripts, local/NAS references, or PC Ollama vision summaries are all acceptable.

## Structured Media Policy

Cleanup must remove or downgrade media payloads in fields that Codex may later deserialize as images:

- `input_image.image_url`: replace the whole object with `{"type":"input_text","text":"..."}` or another omitted-image text note; do not leave a placeholder string as `image_url`.
- `event_msg.payload.images`: remove extracted-media placeholder entries from the list.
- `event_msg.payload.local_images`: remove extracted-media placeholder entries from the list.
- `image_generation_call.result`: remove `result` after extracting the image; keep `id`, `status`, `revised_prompt`, and other metadata.
- `image_generation_end.result`: remove `result` after extracting the image; keep `saved_path`, `status`, `revised_prompt`, and other metadata.
- `mcp_tool_call_end.result.Ok.content[].data`: when a content item has `type` `image`, `audio`, or `video`, extract the Base64 `data` blob and replace that content item with a safe text placeholder; do not keep raw media `data` in the structured MCP result.
- `b64_json` and image `result` Base64 payloads: extract blobs to `media_blobs`, then remove or downgrade the structured media field according to the object type.

Placeholders may remain in plain text fields, command outputs, notes, and audit trails because those values are not re-submitted as media.

Detector and validator code must recursively walk JSON and handle dirty historical data defensively:

- Treat `type` as meaningful only when it is a string.
- Never assume `payload`, `content`, `result`, `images`, or `local_images` has a fixed type.
- Do not print media contents; print path, line number, JSON path, type, length, and category.
- Do not distinguish active and inactive rollouts when deciding whether to scrub.
- After cleanup, warn or fail if any current or archived rollout still has invalid `input_image.image_url`, placeholders inside `images` or `local_images`, placeholders inside `image_generation_call/end.result`, raw media `data` inside MCP image/audio/video content items, large data URL or Base64 media payloads in structured media fields, or JSON parse errors in modified rollout files.

Final reports should separate target rollout status, global current/archived scan status, health-check result, and whether app-server/proxy was restarted. Routine media cleanup should report that no restart occurred.

## Iteration Rule

When a new invalid media shape is found, update the execution scripts and this skill together:

1. Add a failing test that reproduces the new structured field.
2. Add or update detector logic so dry-run reports it.
3. Update scrubber logic so confirmed cleanup removes or downgrades it safely.
4. Add validator checks so cleanup cannot silently leave invalid media references.
5. Run cleanup tests, health tests, dry-run, and targeted rollout scans before reporting completion.

## Update Record

- 2026-05-21: Added confirmed-cleanup backup retention: keep latest 10 `$CODEX_HOME/cleanup_backups` directories by default after successful cleanup.
- 2026-05-27: Added MCP media result cleanup for Computer Use screenshot payloads in `mcp_tool_call_end.result.Ok.content[].data`.
- 2026-05-14: Finalized the maintained flow as health check, dry-run, user-confirmed media-only cleanup, verification, and runtime skill sync. Removed split reference policy files, restart maintenance scripts, and detached launch cleanup wrappers from the current workflow.
