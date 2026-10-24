#!/usr/bin/env python3
"""Keep MeetRec/Localizable.xcstrings in step with the code without opening Xcode.

Xcode fills a String Catalog from the code when it builds in the IDE; xcodebuild only writes the
extracted strings (`*.stringsdata`) into derived data. This script does the IDE's part:

  scripts/l10n.py sync                 build, add new Russian keys, mark vanished ones stale
  scripts/l10n.py merge FILE.json...   add English translations ({"ключ": "key"} or plural forms)
  scripts/l10n.py check                list keys without English (exit 1 if any)
  scripts/l10n.py prune                remove stale keys

Russian is the source language: the Russian text in the code is the key. A plural entry in a
merge file is {"%lld строк": {"plural": {"ru": {"one": …, "few": …, "many": …, "other": …},
"en": {"one": …, "other": …}}}}.
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "MeetRec" / "Localizable.xcstrings"
DERIVED = ROOT / "build" / "dd-l10n"
TARGETS = ("MeetRec.build", "MeetRecMirror.build")


def load():
    return json.loads(CATALOG.read_text())


def save(catalog):
    # Xcode's own layout (" : ", sorted keys), so a later edit in Xcode gives a small diff.
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    CATALOG.write_text(text + "\n")


def extracted_keys():
    subprocess.run(["xcodegen", "generate", "-q"], cwd=ROOT, check=True)
    subprocess.run(["xcodebuild", "-project", "MeetRec.xcodeproj", "-scheme", "MeetRec", "-configuration",
                    "Debug", "-destination", "generic/platform=macOS", "-derivedDataPath", str(DERIVED), "build", "-quiet"],
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    keys = {}
    for path in DERIVED.rglob("*.stringsdata"):
        if not any(target in path.parts for target in TARGETS):
            continue
        data = json.loads(path.read_text())
        for entry in data.get("tables", {}).get("Localizable", []):
            keys.setdefault(entry["key"], entry.get("comment") or "")
    return keys


def needs_translation(key):
    """Keys that are only formats and symbols ("%lld%%", "·") stay as they are."""
    stripped = key
    for spec in ("%lld", "%ld", "%lf", "%@", "%d", "%f", "%%"):
        stripped = stripped.replace(spec, "")
    return any(ch.isalpha() for ch in stripped)


def sync():
    catalog = load()
    strings = catalog.setdefault("strings", {})
    found = extracted_keys()
    added = 0
    for key, comment in found.items():
        entry = strings.setdefault(key, {})
        if not entry:
            added += 1
        entry.pop("extractionState", None)
        if comment:
            entry["comment"] = comment
        if not needs_translation(key):
            entry["shouldTranslate"] = False
    stale = 0
    for key, entry in strings.items():
        if key not in found and entry.get("extractionState") != "manual":
            entry["extractionState"] = "stale"
            stale += 1
    save(catalog)
    print(f"{len(found)} keys in the code, {added} new, {stale} stale")


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def merge(files):
    catalog = load()
    strings = catalog.setdefault("strings", {})
    merged = unknown = 0
    for file in files:
        for key, value in json.loads(Path(file).read_text()).items():
            entry = strings.get(key)
            if entry is None:
                # Not (yet) extracted: e.g. MeetRecMirror, or a key spelled differently. Kept as
                # "manual" so sync does not mark it stale; check lists it.
                entry = strings[key] = {"extractionState": "manual"}
                unknown += 1
            localizations = entry.setdefault("localizations", {})
            if isinstance(value, dict) and "plural" in value:
                for language, forms in value["plural"].items():
                    localizations[language] = {"variations": {"plural": {
                        form: unit(text) for form, text in forms.items()}}}
            else:
                localizations["en"] = unit(value)
            merged += 1
    save(catalog)
    print(f"merged {merged} translations, {unknown} not in the code yet (marked manual)")


def check():
    strings = load().get("strings", {})
    missing = [key for key, entry in strings.items()
               if entry.get("shouldTranslate", True) and entry.get("extractionState") != "stale"
               and "en" not in entry.get("localizations", {})]
    manual = [key for key, entry in strings.items() if entry.get("extractionState") == "manual"]
    stale = [key for key, entry in strings.items() if entry.get("extractionState") == "stale"]
    for key in missing:
        print(f"no English: {key!r}")
    for key in manual:
        print(f"not extracted (manual): {key!r}")
    print(f"{len(strings)} keys, {len(missing)} without English, {len(manual)} manual, {len(stale)} stale")
    return 1 if missing else 0


def prune():
    catalog = load()
    strings = catalog["strings"]
    stale = [key for key, entry in strings.items() if entry.get("extractionState") == "stale"]
    for key in stale:
        del strings[key]
    save(catalog)
    print(f"removed {len(stale)} stale keys")


if __name__ == "__main__":
    command, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("", [])
    if command == "sync":
        sync()
    elif command == "merge" and args:
        merge(args)
    elif command == "check":
        sys.exit(check())
    elif command == "prune":
        prune()
    else:
        print(__doc__)
        sys.exit(2)
