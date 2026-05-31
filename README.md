# Codex Media Hygiene

Small maintenance scripts for diagnosing and scrubbing oversized or invalid media payloads in local Codex rollout JSONL files.

[![tests](https://github.com/gaoqi125/codex-media-hygiene/actions/workflows/tests.yml/badge.svg)](https://github.com/gaoqi125/codex-media-hygiene/actions/workflows/tests.yml)

The tools are conservative by default:

- `codex-health-check.sh` is read-only.
- `codex-cleanup.sh --dry-run` reports risky rollout files without rewriting data.
- `codex-cleanup.sh --confirm` backs up original rollout files before media-only scrubbing.
- Cleanup preserves rollout paths so old conversations can still resolve.
- Cleanup does not restart Codex app-server or proxy processes.

## Files

- `ops/codex-health-check.sh`: reports session storage, large rollout files, oversized records, and Codex process pressure.
- `ops/codex-cleanup.sh`: detects risky rollout media fields and runs dry-run or confirmed cleanup.
- `ops/codex-scrub-rollout-media.py`: recursively extracts embedded image, video, and audio payloads to backup media blobs and replaces structured media fields with safe text.
- `ops/skills/codex-media-hygiene/SKILL.md`: operator workflow for Codex agents.
- `ops/sync-codex-media-hygiene-skill.sh`: optional helper to copy the skill into `$CODEX_HOME/skills/codex-media-hygiene`.

## Usage

Read-only health check:

```bash
bash ops/codex-health-check.sh
```

Dry-run cleanup:

```bash
bash ops/codex-cleanup.sh --dry-run
```

Confirmed cleanup:

```bash
bash ops/codex-cleanup.sh --confirm
```

By default, scripts use `$HOME/.codex`. Override with:

```bash
CODEX_HOME=/path/to/.codex bash ops/codex-cleanup.sh --dry-run
```

## Tests

```bash
bash ops/tests/test_codex_health_check.sh
bash ops/tests/test_codex_cleanup.sh
```

The tests create temporary Codex homes and do not touch your real `$HOME/.codex`.

## Safety Notes

Do not run confirmed cleanup without first reviewing dry-run output. The cleanup path rewrites rollout JSONL files in place after creating backups under `$CODEX_HOME/cleanup_backups`.

See [SECURITY.md](SECURITY.md) and [SUPPORT.md](SUPPORT.md) before sharing diagnostics from real rollout files.
