#!/usr/bin/env python3
"""Static SDK/editor include and target-link dependency ratchet."""
import argparse
import re
import sys
from pathlib import Path

# Frozen direct boundary crossings from dev@871ea997, excluding the unused
# HomePanel.cpp -> Audio.h edge removed by this ticket.
# Existing edges may disappear, never expand without explicit reauthorization.
EDITOR_CORE_ALLOWLIST = {
    ("labs/labovr/HomeWorld.h", "src/core/RenderContributions.h"): "gpu",
    ("labs/labovr/HomeWorld.h", "src/core/TerrainRuntime.h"): "terrain",
    ("labs/labovr/HomeWorld.h", "src/core/GpuSceneCache.h"): "gpu",
    ("labs/labovr/HomePhysics.h", "src/core/TerrainRuntime.h"): "terrain",
    ("labs/labovr/HomeWorld.cpp", "src/core/RenderWorkSelection.h"): "render_work_selection",
}
CLIENT_LINK_ALLOWLIST = {
    "ConsoleVRWorldEditor": {"Core", "LaboVRClientSupport"},
    "LaboVRClientGeometry": set(),
    "LaboVRClientSupport": set(),
}
SOURCE_EXTENSIONS = {".c", ".cpp", ".cu", ".h", ".hpp", ".inl"}


def args_for(cmake, command, target):
    pattern = (r"\b" + re.escape(command) + r"\s*\(\s*"
               + re.escape(target) + r"\s+(.*?)\)")
    return re.findall(pattern, cmake, re.IGNORECASE | re.DOTALL)


def words(body):
    return [v.strip('"') for v in re.findall(r'"[^"]*"|[^\s]+', body)]


def audit(root, fixture):
    issues = []
    cmake = (root / "CMakeLists.txt").read_text(encoding="utf-8")
    cmake = re.sub(r"(?m)^\s*#.*$", "", cmake)
    for target, kind in (("ConsoleVRWorldEditor", "SHARED"),
                         ("LaboVRClientGeometry", "OBJECT"),
                         ("LaboVRClientSupport", "STATIC")):
        statements = args_for(cmake, "add_library", target)
        if len(statements) != 1 or not statements[0].lstrip().startswith(kind):
            issues.append("missing or changed CMake target " + target)

    source_sets = args_for(cmake, "set", "LABOVR_LAB_CLIENT_SOURCES")
    if len(source_sets) != 1:
        issues.append("CMake editor source set missing or ambiguous")
        source_sets = [""]
    paths = lambda s: set(re.findall(
        r'(?<![A-Za-z0-9_./-])[A-Za-z0-9_./-]+\.(?:cpp|c|cu|h|hpp|inl)\b',
        re.sub(r'\$\{(?:CMAKE_CURRENT_SOURCE_DIR|PROJECT_SOURCE_DIR|CMAKE_SOURCE_DIR)\}/',
               '', s)))
    editor_roots = paths(source_sets[0])
    for target in CLIENT_LINK_ALLOWLIST:
        for command in ("add_library", "target_sources"):
            for statement in args_for(cmake, command, target):
                editor_roots.update(paths(statement))
                for variable in re.findall(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', statement):
                    for source_set in args_for(cmake, "set", variable):
                        editor_roots.update(paths(source_set))
    if "labs/labovr/HomePanel.cpp" not in editor_roots:
        issues.append("HomePanel.cpp absent from editor target source set")

    sdk_dir = root / "src/cartridge_sdk"
    sdk_roots = sorted(p.relative_to(root).as_posix()
                       for p in sdk_dir.rglob("*")
                       if p.is_file() and p.suffix in SOURCE_EXTENSIONS)
    if not sdk_roots:
        issues.append("SDK source inventory empty")

    links = {}
    for target, allowed in CLIENT_LINK_ALLOWLIST.items():
        actual = set()
        for statement in args_for(cmake, "target_link_libraries", target):
            actual.update(v for v in words(statement)
                          if v.upper() not in ("PUBLIC", "PRIVATE", "INTERFACE"))
        links[target] = actual
        for item in sorted(actual - allowed):
            issues.append(target + " adds linked library " + item)
        for statement in args_for(cmake, "target_include_directories", target):
            for item in words(statement):
                normalized = item.replace("\\", "/")
                if re.search(r'(?:^|/)src/core(?:/|$|>)', normalized):
                    issues.append(target + " adds Core include directory " + item)

    if "Core" in links["LaboVRClientSupport"] or "Core" in links["LaboVRClientGeometry"]:
        issues.append("SDK or geometry target links back to Core")

    scanned = set()
    found_editor_edges = set()
    root = root.resolve()

    def relative(path):
        try:
            return path.resolve().relative_to(root).as_posix()
        except ValueError:
            return None

    def resolve(owner, spelling):
        for candidate in (owner.parent / spelling, root / spelling,
                          root / "labs/labovr" / spelling,
                          root / "src/cartridge_sdk" / spelling,
                          root / "src/cartridge_api" / spelling,
                          root / "src/core" / spelling):
            if relative(candidate) is not None and candidate.is_file():
                return candidate
        return None

    def visit(start, group):
        pending = [root / start]
        while pending:
            path = pending.pop()
            filename = relative(path)
            if not filename or (group, filename) in scanned:
                continue
            scanned.add((group, filename))
            if not path.is_file():
                issues.append(group + " missing source " + filename)
                continue
            source = path.read_text(encoding="utf-8-sig")
            includes = re.findall(r'^[ \t]*#[ \t]*include[ \t]*[<"]([^">]+)[">]',
                                  source, re.MULTILINE)
            if fixture and group == "sdk" and filename == "src/cartridge_sdk/ClientMath.hpp":
                includes.append("../core/Audio.h")
            for spelling in includes:
                spelling = spelling.replace("\\", "/")
                candidate = resolve(path, spelling)
                destination = relative(candidate) if candidate else None
                names_private_core = bool(re.search(r"(^|/)(?:src/)?core/", spelling))
                if (destination and destination.startswith("src/core/")) or names_private_core:
                    edge = (filename, destination or spelling)
                    if group == "sdk":
                        issues.append("SDK -> Core forbidden: " + str(edge))
                    else:
                        found_editor_edges.add(edge)
                        if edge not in EDITOR_CORE_ALLOWLIST:
                            issues.append("new private include: " + str(edge))
                    continue
                if destination and destination.startswith(
                    ("labs/labovr/", "src/cartridge_sdk/", "src/cartridge_api/")
                ):
                    pending.append(candidate)

    for path in sdk_roots:
        visit(path, "sdk")
    for path in sorted(editor_roots):
        visit(path, "editor")

    print("SDK direct/transitive Core imports: "
          + str(sum("SDK -> Core forbidden" in issue for issue in issues)))
    for label in ("terrain", "gpu", "render_work_selection"):
        for edge in sorted(found_editor_edges):
            if EDITOR_CORE_ALLOWLIST.get(edge) == label:
                print("existing " + label + " debt: " + " -> ".join(edge))
    if "Core" in links["ConsoleVRWorldEditor"]:
        print("existing target link debt: ConsoleVRWorldEditor -> Core")
    for issue in sorted(set(issues)):
        print("boundary violation: " + issue, file=sys.stderr)
    return 1 if issues else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--fixture-include", action="store_true",
                        help="Virtually inject a new SDK include of Core/Audio.h (must fail)")
    options = parser.parse_args()
    sys.exit(audit(options.root.resolve(), options.fixture_include))
