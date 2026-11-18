#!/usr/bin/env python3
"""Validate the repository-native Biz-Kit plugin package."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins" / "biz-kit"
MANIFEST = PLUGIN / "plugin.json"
MARKETPLACE = ROOT / ".agents" / "plugins" / "marketplace.json"
SKILLS = PLUGIN / "skills"
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)


def fail(message: str) -> None:
    raise ValueError(message)


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"missing {path.relative_to(ROOT)}")
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {path.relative_to(ROOT)}: {error}")
    if not isinstance(value, dict):
        fail(f"{path.relative_to(ROOT)} must contain a JSON object")
    return value


def parse_frontmatter(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    match = FRONTMATTER_RE.match(text)
    if not match:
        fail(f"{path.relative_to(ROOT)} lacks YAML frontmatter")
    fields: dict[str, str] = {}
    for line in match.group(1).splitlines():
        if ":" not in line:
            fail(f"invalid frontmatter line in {path.relative_to(ROOT)}: {line!r}")
        key, value = line.split(":", 1)
        fields[key.strip()] = value.strip()
    return fields


def main() -> int:
    manifest = load_json(MANIFEST)
    expected_schema = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
    if manifest.get("$schema") != expected_schema:
        fail("plugin manifest does not declare the portable Agent Plugins schema")
    if manifest.get("name") != "biz-kit":
        fail("plugin manifest name must remain biz-kit")
    if not re.fullmatch(r"\d+\.\d+\.\d+", str(manifest.get("version", ""))):
        fail("plugin version must be semantic major.minor.patch")
    if not str(manifest.get("description", "")).strip():
        fail("plugin description is required")

    skill_files = sorted(SKILLS.glob("*/SKILL.md"))
    if not skill_files:
        fail("plugin must contain at least one skill")
    names: set[str] = set()
    for path in skill_files:
        fields = parse_frontmatter(path)
        name = fields.get("name", "")
        description = fields.get("description", "")
        if not NAME_RE.fullmatch(name):
            fail(f"invalid skill name {name!r} in {path.relative_to(ROOT)}")
        if name != path.parent.name:
            fail(f"skill name/path mismatch in {path.relative_to(ROOT)}")
        if name in names:
            fail(f"duplicate skill name {name}")
        if not description:
            fail(f"missing skill description in {path.relative_to(ROOT)}")
        names.add(name)

    marketplace = load_json(MARKETPLACE)
    entries = marketplace.get("plugins")
    if not isinstance(entries, list):
        fail("marketplace plugins must be an array")
    matches = [entry for entry in entries if entry.get("name") == "biz-kit"]
    if len(matches) != 1:
        fail("marketplace must contain exactly one biz-kit entry")
    entry = matches[0]
    if entry.get("source") != {"source": "local", "path": "./plugins/biz-kit"}:
        fail("marketplace source must point to ./plugins/biz-kit")
    policy = entry.get("policy", {})
    if policy.get("installation") != "AVAILABLE":
        fail("biz-kit plugin must be available for installation")
    if policy.get("authentication") not in {"ON_INSTALL", "ON_USE"}:
        fail("invalid authentication policy")

    print(f"validated biz-kit plugin {manifest['version']} with {len(names)} skills")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
