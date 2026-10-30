#!/usr/bin/env python3
"""Creator-run MSVC x64 ABI layout probe; never rewrites the frozen V1 fixture."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
API = ROOT / "src" / "cartridge_api"
FROZEN = ROOT / "tests" / "abi" / "fixtures" / "v1" / "layout_win64.json"
STRUCT = re.compile(
    r"\btypedef\s+struct\s+([A-Za-z_]\w*)\s*\{([\s\S]*?)\}\s*([A-Za-z_]\w*)\s*;"
)
FUNC = re.compile(r"\(\s*(?:LABOVR_PLUGIN_CALL\s*)?\*\s*([A-Za-z_]\w*)\s*\)")
PLAIN = re.compile(r"^((?:(?:const|volatile|struct|unsigned|signed)\s+)*[A-Za-z_]\w*)\s*(.*)$")
DECL = re.compile(r"^\**\s*([A-Za-z_]\w*)\s*(?:\[[^\]]+\]\s*)*$")


def public_records():
    """Discover every defined public C record/table, including .inl table members."""
    inl = (API / "LaboVRLandscapeService.inl").read_text(encoding="utf-8")
    records = {}
    for header in sorted(API.glob("*.h")):
        source = header.read_text(encoding="utf-8")
        source = source.replace('#include "LaboVRLandscapeService.inl"', inl)
        source = re.sub(r"/\*[\s\S]*?\*/", "", source)
        source = re.sub(r"//[^\n]*", "", source)
        source = re.sub(r"^\s*#.*$", "", source, flags=re.M)
        for found in STRUCT.finditer(source):
            typename, body, alias = found.groups()
            if typename != alias:
                raise ValueError(f"{header.name}: struct/alias mismatch: {typename} / {alias}")
            if typename in records:
                raise ValueError(f"duplicate public definition: {typename}")
            # The one anonymous union has two pointer aliases at the same offset.
            # Keep both names; actual compiler offsetof is authoritative.
            body = re.sub(r"\bunion\s*\{([^{}]*)\}\s*;", lambda x: x.group(1), body)
            members = []
            for statement in (item.strip() for item in body.split(";")):
                if not statement:
                    continue
                fn = FUNC.search(statement)
                if fn:
                    members.append(fn.group(1))
                    continue
                plain = PLAIN.match(" ".join(statement.split()))
                if not plain:
                    raise ValueError(f"{typename}: cannot parse declaration: {statement}")
                for item in plain.group(2).split(","):
                    name = DECL.match(item.strip())
                    if not name:
                        raise ValueError(f"{typename}: cannot parse member: {item}")
                    members.append(name.group(1))
            if not members or len(members) != len(set(members)):
                raise ValueError(f"{typename}: empty or duplicate member list")
            records[typename] = {"header": header.name, "members": members}
    if not records:
        raise ValueError("no public ABI records discovered")
    return records


def make_probe(records):
    headers = sorted({entry["header"] for entry in records.values()})
    lines = ["#include <cstddef>", "#include <cstdio>", "#include <cstdint>"]
    lines += [f'#include "{header}"' for header in headers]
    lines += ["#if !defined(_MSC_VER) || !defined(_WIN64)",
              "#error MSVC x64 is required for ABI layout certification",
              "#endif", "static_assert(sizeof(void*) == 8);", "int main() {"]
    for typename, entry in sorted(records.items()):
        lines.append(
            f'  std::printf("T|{typename}|%zu|%zu\\n", sizeof({typename}), alignof({typename}));'
        )
        for member in entry["members"]:
            lines.append(
                f'  std::printf("F|{typename}|{member}|%zu|%zu\\n", '
                f'offsetof({typename}, {member}), '
                f'sizeof((({typename}*)0)->{member}));'
            )
    lines += ["  return 0;", "}"]
    return "\n".join(lines) + "\n"


def measure(records):
    if os.name != "nt" or sys.maxsize <= 2**32:
        raise RuntimeError("The frozen V1 baseline must be measured on Windows x64.")
    compiler = shutil.which("cl.exe") or shutil.which("cl")
    if not compiler:
        raise RuntimeError("MSVC cl.exe is required; run inside a VS x64 developer shell.")
    with tempfile.TemporaryDirectory(prefix="consolevr-abi-layout-") as tmp:
        work = Path(tmp)
        src = work / "layout_probe.cpp"
        exe = work / "layout_probe.exe"
        src.write_text(make_probe(records), encoding="utf-8")
        command = [compiler, "/nologo", "/std:c++20", "/EHsc", "/Zp8",
                   "/I" + str(API), "/Fo" + str(work / "layout_probe.obj"),
                   "/Fe" + str(exe), str(src)]
        compiled = subprocess.run(command, cwd=work, capture_output=True, text=True)
        if compiled.returncode:
            raise RuntimeError("MSVC layout probe compilation failed:\n" +
                               compiled.stdout + compiled.stderr)
        result = subprocess.run([str(exe)], cwd=work, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError("MSVC layout probe failed:\n" + result.stdout + result.stderr)
        observed = {}
        for row in result.stdout.splitlines():
            parts = row.split("|")
            if len(parts) == 4 and parts[0] == "T":
                _, name, size, align = parts
                observed[name] = {"size": int(size), "align": int(align), "fields": {}}
            elif len(parts) == 5 and parts[0] == "F":
                _, name, member, offset, size = parts
                if name not in observed:
                    raise RuntimeError(f"unregistered layout member: {name}.{member}")
                observed[name]["fields"][member] = {
                    "offset": int(offset), "size": int(size)
                }
            else:
                raise RuntimeError(f"malformed probe output: {row}")
        if set(observed) != set(records):
            raise RuntimeError("MSVC probe omitted public ABI records")
        for name in records:
            if list(observed[name]["fields"]) != records[name]["members"]:
                raise RuntimeError(f"MSVC probe omitted members of {name}")
        return observed


def compare(frozen, observed):
    """Validate the unchanged prefix and log genuine append-only additions."""
    issues, additions = [], []
    for name, old in frozen.items():
        now = observed.get(name)
        if now is None:
            issues.append(f"REMOVED RECORD {name}")
            continue
        original = list(old["fields"])
        current = list(now["fields"])
        if current[:len(original)] != original:
            issues.append(f"REORDERED/REMOVED/INSERTED FIELD {name}: " +
                          f"expected prefix {original}, got {current}")
            continue
        for field in original:
            prior, actual = old["fields"][field], now["fields"][field]
            for key in ("offset", "size"):
                if prior[key] != actual[key]:
                    issues.append(f"LAYOUT DRIFT {name}.{field}.{key}: " +
                                  f"{prior[key]} -> {actual[key]}")
        suffix = current[len(original):]
        if not suffix:
            for key in ("size", "align"):
                if old[key] != now[key]:
                    issues.append(f"LAYOUT DRIFT {name}.{key}: " +
                                  f"{old[key]} -> {now[key]}")
        else:
            if now["size"] < old["size"]:
                issues.append(f"SHRUNK RECORD {name}: {old['size']} -> {now['size']}")
            if now["align"] != old["align"]:
                issues.append(f"ALIGNMENT DRIFT ON SUFFIX {name}: " +
                              f"{old['align']} -> {now['align']}")
            for member in suffix:
                place = now["fields"][member]
                additions.append(
                    f"APPEND-ONLY SUFFIX {name}.{member} "
                    f"offset={place['offset']} size={place['size']}"
                )
                if place["offset"] < old["size"]:
                    issues.append(f"SUFFIX OVERLAPS FROZEN SIZE {name}.{member}")
    for name in observed.keys() - frozen.keys():
        additions.append(f"NEW PUBLIC RECORD {name} (requires an explicit baseline decision)")
    return issues, additions


def self_check():
    old = {"Record": {"size": 8, "align": 4, "fields": {
        "first": {"offset": 0, "size": 4}, "second": {"offset": 4, "size": 4}}}}
    import copy
    displaced = copy.deepcopy(old)
    displaced["Record"]["fields"]["second"]["offset"] = 5
    widened = copy.deepcopy(old)
    widened["Record"]["fields"]["first"]["size"] = 8
    appended = copy.deepcopy(old)
    appended["Record"]["size"] = 12
    appended["Record"]["fields"]["third"] = {"offset": 8, "size": 4}
    if not compare(old, displaced)[0] or not compare(old, widened)[0]:
        raise RuntimeError("Layout comparison failed to reject a changed offset/width")
    errors, suffixes = compare(old, appended)
    if errors or len(suffixes) != 1:
        raise RuntimeError("Layout comparison failed to identify append-only suffix")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true",
                        help="Compare MSVC x64 measurement with the immutable fixture")
    parser.add_argument("--self-check", action="store_true",
                        help="Check comparison logic without invoking MSVC")
    parser.add_argument("--observed", type=Path, help="Optional separate capture of measurements")
    args = parser.parse_args()
    self_check()
    if args.self_check:
        print("ABI layout comparison controls: offset, width and suffix OK")
        return 0
    if args.observed and args.observed.resolve() == FROZEN.resolve():
        raise ValueError("Refusing to overwrite the frozen fixture")
    baseline = json.loads(FROZEN.read_text(encoding="utf-8"))
    if (baseline.get("schema_version") != 1 or
        baseline.get("target") != "windows-msvc-x64" or
        baseline.get("pointer_bits") != 64 or baseline.get("packing") != 8):
        raise ValueError("Unexpected layout baseline metadata")
    records = public_records()
    measured = measure(records)
    if args.observed:
        args.observed.parent.mkdir(parents=True, exist_ok=True)
        args.observed.write_text(json.dumps({
            "target": "windows-msvc-x64", "records": measured
        }, indent=2) + "\n", encoding="utf-8")
    failures, additions = compare(baseline["records"], measured)
    for item in additions:
        print(item)
    for issue in failures:
        print("FAIL " + issue, file=sys.stderr)
    print(f"MSVC x64 ABI: {len(measured)} records; "
          f"{len(additions)} additions; {len(failures)} regressions")
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, KeyError) as exc:
        print(f"ABI layout error: {exc}", file=sys.stderr)
        sys.exit(1)
