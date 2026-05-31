# Security Policy

## Scope

This project handles local Codex rollout files that may contain private conversation text, local paths, and embedded media payloads. Treat every rollout file as sensitive.

## Reporting

Please report security issues through GitHub Security Advisories when available, or by opening a minimal public issue that does not include private rollout content.

Do not paste:

- API keys, tokens, cookies, or credentials
- private conversation text
- Base64 media payloads
- personal file paths that reveal private information

Safe reports should include only:

- operating system
- command run
- JSON field path
- byte length
- redacted sample shape
- expected and actual behavior

## Maintainer Response

Security-sensitive cleanup changes should include:

- a dry-run detector
- backup-first scrub behavior
- a validator that proves unsafe structured fields were removed
- tests using synthetic fixtures only
