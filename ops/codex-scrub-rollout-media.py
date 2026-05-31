#!/usr/bin/env python3
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import mimetypes
import os
import re
import shutil
import sys
from pathlib import Path


DATA_URL_RE = re.compile(
    r"data:(?P<mime>(?:image|video|audio)/[A-Za-z0-9.+-]+);base64,(?P<data>[A-Za-z0-9+/=\r\n]+)"
)
BASE64_KEYS = {"b64_json", "result"}
PLACEHOLDER_PREFIX = "[codex-cleanup media extracted:"
MCP_MEDIA_TYPES = {"image", "video", "audio"}


def looks_like_base64(value: str) -> bool:
    if len(value) < 128:
        return False
    compact = "".join(value.split())
    if len(compact) % 4 != 0:
        return False
    return re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", compact) is not None


def decode_base64(value: str) -> bytes:
    compact = "".join(value.split())
    return base64.b64decode(compact, validate=False)


def extension_for_mime(mime: str | None) -> str:
    if not mime:
        return ".bin"
    return mimetypes.guess_extension(mime) or ".bin"


class Scrubber:
    def __init__(self, media_dir: Path, threshold: int):
        self.media_dir = media_dir
        self.threshold = threshold
        self.media_threshold = int(os.environ.get("CODEX_MEDIA_DATA_URL_MIN_BYTES", str(threshold)))
        self.count = 0
        self.total_bytes = 0

    def write_blob(self, payload: bytes, mime: str | None, ext_override: str | None = None) -> str:
        digest = hashlib.sha256(payload).hexdigest()
        ext = ext_override or extension_for_mime(mime)
        path = self.media_dir / f"{digest}{ext}"
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            path.write_bytes(payload)
        self.count += 1
        self.total_bytes += len(payload)
        return f"[codex-cleanup media extracted: sha256={digest} bytes={len(payload)} backup=media_blobs/{path.name}]"

    def scrub_string(self, value: str, key: str | None) -> str:
        def replace_data_url(match: re.Match[str]) -> str:
            encoded = match.group("data")
            try:
                raw = decode_base64(encoded)
                return self.write_blob(raw, match.group("mime"))
            except binascii.Error:
                raw = encoded.encode("ascii", errors="ignore")
                return self.write_blob(raw, None, ".base64.txt")

        replaced = DATA_URL_RE.sub(replace_data_url, value)
        if replaced != value:
            return replaced

        if key in BASE64_KEYS and len(value) > self.threshold and looks_like_base64(value):
            raw = decode_base64(value)
            return self.write_blob(raw, None)

        return value

    def scrub_json(self, value, key: str | None = None):
        if isinstance(value, dict):
            value_type = value.get("type")
            if isinstance(value_type, str) and value_type in MCP_MEDIA_TYPES and isinstance(value.get("data"), str):
                mime = value.get("mimeType") if isinstance(value.get("mimeType"), str) else None
                data = value["data"]
                if len("".join(data.split())) >= self.media_threshold and looks_like_base64(data):
                    placeholder = self.write_blob(decode_base64(data), mime)
                    return {"type": "text", "text": placeholder}

            scrubbed_dict = {}
            changed_image_refs = False
            for image_key in ("images", "local_images"):
                image_refs = value.get(image_key)
                if not isinstance(image_refs, list):
                    continue
                kept_refs = []
                for image_ref in image_refs:
                    if isinstance(image_ref, str):
                        scrubbed_ref = self.scrub_string(image_ref, image_key)
                        if scrubbed_ref.startswith(PLACEHOLDER_PREFIX):
                            changed_image_refs = True
                            continue
                        kept_refs.append(scrubbed_ref)
                        changed_image_refs = changed_image_refs or scrubbed_ref != image_ref
                    else:
                        kept_refs.append(image_ref)
                scrubbed_dict[image_key] = kept_refs
            if changed_image_refs:
                merged = {**value, **scrubbed_dict}
                return {k: self.scrub_json(v, k) for k, v in merged.items()}

            if (
                isinstance(value_type, str)
                and value_type in {"image_generation_call", "image_generation_end"}
                and "result" in value
            ):
                result = value.get("result")
                if isinstance(result, str):
                    scrubbed = self.scrub_string(result, "result")
                    if scrubbed != result or scrubbed.startswith(PLACEHOLDER_PREFIX):
                        return {k: self.scrub_json(v, k) for k, v in value.items() if k != "result"}

            if value_type == "input_image" and "image_url" in value:
                image_url = value.get("image_url")
                if isinstance(image_url, str):
                    scrubbed = self.scrub_string(image_url, "image_url")
                    if scrubbed != image_url or scrubbed.startswith(PLACEHOLDER_PREFIX):
                        return {"type": "input_text", "text": scrubbed}
                    if not (
                        image_url.startswith("http://")
                        or image_url.startswith("https://")
                        or image_url.startswith("data:image/")
                    ):
                        return {"type": "input_text", "text": f"[codex-cleanup image omitted: invalid image_url]"}
            return {k: self.scrub_json(v, k) for k, v in value.items()}
        if isinstance(value, list):
            return [self.scrub_json(item, key) for item in value]
        if isinstance(value, str):
            return self.scrub_string(value, key)
        return value


def main() -> int:
    if len(sys.argv) != 5:
        print(
            "usage: codex-scrub-rollout-media.py ROLLOUT_JSONL BACKUP_DIR CODEX_HOME THRESHOLD_BYTES",
            file=sys.stderr,
        )
        return 64

    rollout = Path(sys.argv[1])
    backup_dir = Path(sys.argv[2])
    codex_home = Path(sys.argv[3])
    threshold = int(sys.argv[4])

    media_dir = backup_dir / "media_blobs"
    scrubber = Scrubber(media_dir, threshold)
    output_lines: list[str] = []
    changed = False

    with rollout.open("r", encoding="utf-8") as source:
        for line in source:
            newline = "\n" if line.endswith("\n") else ""
            body = line[:-1] if newline else line
            try:
                parsed = json.loads(body)
            except json.JSONDecodeError:
                scrubbed = scrubber.scrub_string(body, None)
                changed = changed or scrubbed != body
                output_lines.append(scrubbed + newline)
                continue

            scrubbed_json = scrubber.scrub_json(parsed)
            changed = changed or scrubbed_json != parsed
            output_lines.append(json.dumps(scrubbed_json, ensure_ascii=False, separators=(",", ":")) + newline)

    if not changed:
        print(f"no media payloads found: {rollout}")
        return 0

    preserve_original = os.environ.get("CODEX_SCRUB_PRESERVE_ORIGINAL", "1") != "0"
    original_backup = None
    if preserve_original:
        relative = rollout.relative_to(codex_home)
        original_backup = backup_dir / "original_rollouts" / relative
        original_backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(rollout, original_backup)

    tmp = rollout.with_suffix(rollout.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as target:
        target.writelines(output_lines)
    os.replace(tmp, rollout)

    backup_note = f"original_backup={original_backup}" if original_backup else "original_backup=not_preserved_for_existing_backup_file"
    print(f"scrubbed {scrubber.count} media payload(s), extracted {scrubber.total_bytes} bytes, {backup_note}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
