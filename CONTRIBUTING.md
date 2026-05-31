# Contributing

This repository is intentionally small and conservative. Its goal is to make Codex rollout media cleanup safer, not broader.

## Development

Run both test scripts before opening a pull request:

```bash
bash ops/tests/test_codex_health_check.sh
bash ops/tests/test_codex_cleanup.sh
```

## Safety Rules

- Do not print or commit Base64 media payloads.
- Do not add credentials, rollout samples from real users, or private local paths.
- Add a detector, scrubber behavior, and validation test together for every new media field shape.
- Keep confirmed cleanup backup-first and media-only.
- Do not add automatic app-server restarts.
