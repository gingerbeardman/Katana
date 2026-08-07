#!/usr/bin/env python3
"""
Build a compact serial → title database for Katana from GameDB-Dreamcast.

Downloads the latest Dreamcast.titles.json + Dreamcast.data.tsv from
https://github.com/niemasd/GameDB-Dreamcast and emits a JSON map with
normalized serial aliases for IP.BIN product lookup.

Usage:
  python3 Tools/scripts/build-gamedb.py
  python3 Tools/scripts/build-gamedb.py --out Katana/Resources/GameDB/dreamcast-titles.json
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

TITLES_URL = (
    "https://github.com/niemasd/GameDB-Dreamcast/releases/latest/download/Dreamcast.titles.json"
)
DATA_URL = (
    "https://github.com/niemasd/GameDB-Dreamcast/releases/latest/download/Dreamcast.data.tsv"
)
SOURCE = "GameDB-Dreamcast"
SOURCE_URL = "https://github.com/niemasd/GameDB-Dreamcast"
SOURCE_LICENSE = "GPL-3.0"


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "Katana-GameDB-Builder/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def clean_serial(raw: str) -> str:
    s = raw.strip().upper()
    s = s.replace(" ", "")
    # Collapse common separators for alias generation later; keep canonical form dashed.
    return s


def serial_aliases(serial: str) -> list[str]:
    """Expand one product/catalog ID into lookup aliases (IP.BIN variants)."""
    s = clean_serial(serial)
    if not s:
        return []

    aliases: list[str] = []
    seen: set[str] = set()

    def add(x: str) -> None:
        x = clean_serial(x)
        if not x or x in seen:
            return
        seen.add(x)
        aliases.append(x)

    add(s)
    nodash = s.replace("-", "")
    add(nodash)

    # MK-51000 ↔ 51000 ↔ MK51000
    if s.startswith("MK-"):
        rest = s[3:]
        add(rest)
        add(rest.replace("-", ""))
        add("MK" + rest.replace("-", ""))
    elif s.startswith("MK") and len(s) > 2 and s[2:].replace("-", "").isdigit():
        rest = s[2:]
        add(rest)
        add("MK-" + rest)

    # T-17707N ↔ 17707N ↔ T17707N
    if s.startswith("T-"):
        rest = s[2:]
        add(rest)
        add(rest.replace("-", ""))
        add("T" + rest.replace("-", ""))
    elif re.fullmatch(r"T[0-9].*", s):
        rest = s[1:]
        add(rest)
        add("T-" + rest)

    # HDR-0076 ↔ 0076 / HDR0076
    if s.startswith("HDR-"):
        rest = s[4:]
        add(rest)
        add(rest.replace("-", ""))
        add("HDR" + rest.replace("-", ""))
    elif s.startswith("HDR") and len(s) > 3:
        rest = s[3:]
        add(rest)
        add("HDR-" + rest.lstrip("-"))

    # Pure catalog digits often appear as MK-##### in IP.BIN
    if re.fullmatch(r"\d+", s):
        add("MK-" + s)
        add("MK" + s)
        # JP-style sometimes without prefix in shorter form — keep as-is only

    # Digit groups like 610-7000
    if re.fullmatch(r"\d+(-\d+)+", s):
        add(nodash)

    return aliases


def load_regions(tsv_bytes: bytes) -> dict[str, str]:
    text = tsv_bytes.decode("utf-8")
    reader = csv.DictReader(io.StringIO(text), delimiter="\t")
    out: dict[str, str] = {}
    for row in reader:
        rid = (row.get("ID") or "").strip()
        region = (row.get("region") or "").strip()
        if rid:
            out[rid] = region
    return out


def build(titles: dict[str, str], regions: dict[str, str]) -> dict:
    # primary id → record
    records: dict[str, dict] = {}
    for raw_id, title in titles.items():
        pid = clean_serial(raw_id)
        title = (title or "").strip()
        if not pid or not title:
            continue
        records[pid] = {
            "id": pid,
            "title": title,
            "region": regions.get(raw_id) or regions.get(pid) or "",
        }

    # alias → id (prefer longer / more specific ids on collision if titles match)
    alias_to_id: dict[str, str] = {}
    collisions = 0
    for pid, rec in records.items():
        for alias in serial_aliases(pid):
            if alias in alias_to_id:
                other = alias_to_id[alias]
                if other == pid:
                    continue
                if records[other]["title"] == rec["title"]:
                    # Same game, keep longer / more specific key as primary target
                    if len(pid) >= len(other):
                        alias_to_id[alias] = pid
                    continue
                collisions += 1
                # Prefer existing if current alias equals the other id exactly
                if alias == other:
                    continue
                if alias == pid:
                    alias_to_id[alias] = pid
                continue
            alias_to_id[alias] = pid

    # Compact map for app: alias → {title, region, id}
    lookup: dict[str, dict] = {}
    for alias, pid in alias_to_id.items():
        rec = records[pid]
        lookup[alias] = {
            "title": rec["title"],
            "region": rec["region"],
            "id": rec["id"],
        }

    return {
        "version": 1,
        "source": SOURCE,
        "sourceURL": SOURCE_URL,
        "sourceLicense": SOURCE_LICENSE,
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "primaryCount": len(records),
        "aliasCount": len(lookup),
        "titles": lookup,
    }


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    default_out = root / "Katana" / "Resources" / "GameDB" / "dreamcast-titles.json"

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=default_out)
    ap.add_argument("--titles", type=Path, help="Local titles JSON (skip download)")
    ap.add_argument("--data", type=Path, help="Local data TSV (skip download)")
    args = ap.parse_args()

    if args.titles:
        titles = json.loads(args.titles.read_text(encoding="utf-8"))
    else:
        print(f"Downloading {TITLES_URL} …", file=sys.stderr)
        titles = json.loads(fetch(TITLES_URL).decode("utf-8"))

    if args.data:
        regions = load_regions(args.data.read_bytes())
    else:
        print(f"Downloading {DATA_URL} …", file=sys.stderr)
        regions = load_regions(fetch(DATA_URL))

    db = build(titles, regions)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(db, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(
        f"Wrote {args.out} — {db['primaryCount']} titles, {db['aliasCount']} aliases, "
        f"{args.out.stat().st_size} bytes",
        file=sys.stderr,
    )
    # Spot-check common IP.BIN-style keys
    sample_keys = ["MK-51000", "51000", "T-17707N", "17707N", "HDR-0076"]
    for k in sample_keys:
        hit = db["titles"].get(k) or db["titles"].get(k.replace("-", ""))
        print(f"  lookup {k!r} → {hit}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
