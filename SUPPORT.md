# Support

Use GitHub Issues for reproducible bugs and GitHub Discussions for workflow questions.

Before opening an issue:

```bash
bash ops/codex-health-check.sh
bash ops/codex-cleanup.sh --dry-run
```

Share command output only after removing private paths or conversation text. Never paste Base64 media payloads or credentials.

Supported maintenance scope:

- Codex rollout media payload detection
- dry-run cleanup diagnostics
- backup-first media scrubbing
- safety tests for structured media fields

Out of scope:

- recovering deleted rollout files without backups
- debugging unrelated GitHub or browser authentication issues
- handling private provider credentials
