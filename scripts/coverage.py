#!/usr/bin/env python3
"""Source-location coverage gates. Only normalized, source-hashed reports are accepted."""
import argparse
from collections import defaultdict
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


class CoverageError(Exception):
    pass


def command(args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs)


def read_json(path):
    return json.loads(Path(path).read_text())


def save_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def inventory(root, package, project, exclusions):
    """Use evaluated SwiftPM shipping reachability and cross-check Xcode source groups."""
    if package.get("dependencies"):
        raise CoverageError("Review third-party/generated source accounting before adding package dependencies")
    targets = {t["name"]: t for t in package["targets"]}
    products = [p for p in package["products"] if p["name"] == "Stillmatter"]
    if len(products) != 1:
        raise CoverageError("Expected exactly one Stillmatter shipping product")
    reachable = set()

    def visit(name):
        if name in reachable:
            return
        if name not in targets:
            raise CoverageError(f"Unaccounted shipping dependency: {name}")
        reachable.add(name)
        for dependency in targets[name].get("target_dependencies", []):
            visit(dependency)

    for name in products[0]["targets"]:
        visit(name)
    files = {}
    for name in sorted(reachable):
        target = targets[name]
        if target.get("type") == "test":
            raise CoverageError(f"Test target in shipping product: {name}")
        for source in target.get("sources", []):
            path = Path(target["path"]) / source
            if path.suffix != ".swift":
                continue
            relative = path.as_posix()
            files[relative] = {"module": name, "sha256": hashlib.sha256((root / path).read_bytes()).hexdigest()}
    objects = project["objects"]
    for name in reachable:
        native = [(identifier, o) for identifier, o in objects.items() if o.get("isa") == "PBXNativeTarget" and o.get("name") == name]
        if len(native) != 1:
            raise CoverageError(f"No unique Xcode shipping target for {name}")
        native_id, native_target = native[0]
        for phase_id in native_target.get("buildPhases", []):
            phase = objects[phase_id]
            if phase.get("isa") == "PBXSourcesBuildPhase" and phase.get("files"):
                raise CoverageError(f"Review explicit Xcode source membership for {name}")
        groups = native_target.get("fileSystemSynchronizedGroups", [])
        xcode_files = set()
        for group_id in groups:
            group = objects[group_id]
            for exception_id in group.get("exceptions", []):
                exception_target = objects[exception_id].get("target")
                if exception_target is None or exception_target == native_id:
                    raise CoverageError(f"Review Xcode source exclusions for {name}")
            xcode_files.update(p.relative_to(root).as_posix() for p in (root / group["path"]).rglob("*.swift"))
        expected = {p for p, value in files.items() if value["module"] == name}
        if xcode_files != expected:
            raise CoverageError(f"SwiftPM/Xcode source inventory differs for {name}: {sorted(xcode_files ^ expected)}")
    unknown = {p.relative_to(root).as_posix() for p in (root / "Sources").rglob("*.swift")} - files.keys()
    if unknown:
        raise CoverageError(f"Unaccounted Sources files: {sorted(unknown)}")
    if exclusions.keys() - files.keys():
        raise CoverageError("Stale coverage exclusion")
    for path, exclusion in exclusions.items():
        reason = exclusion["reason"]
        if not reason.strip():
            raise CoverageError(f"Missing exclusion reason: {path}")
        if exclusion["sha256"] != files[path]["sha256"]:
            raise CoverageError(f"Excluded source changed; review shipping applicability: {path}")
        files[path]["excluded"] = reason
    return {"schema": 1, "configuration": "release-no-optimization", "files": files}


def current_inventory(root):
    package = json.loads(command(["swift", "package", "--package-path", str(root), "describe", "--type", "json"]))
    project = json.loads(command(["plutil", "-convert", "json", "-o", "-", str(root / "Stillmatter.xcodeproj/project.pbxproj")]))
    policy = read_json(root / "scripts/coverage-policy.json")
    result = inventory(root, package, project, policy["excluded_sources"])
    result["build_inputs"] = {
        "package_sha256": hashlib.sha256((root / "Package.swift").read_bytes()).hexdigest(),
        "shipping_release_settings": shipping_release_settings(project, {v["module"] for v in result["files"].values()}),
        "swift": command(["swift", "--version"]).strip(),
        "xcode": command(["xcodebuild", "-version"]).strip(),
    }
    return result


def shipping_release_settings(project, modules):
    """Fingerprint shipping build flags without invalidating coverage for test-target additions."""
    objects = project["objects"]
    result = {}
    owners = {"project": objects[project["rootObject"]]}
    owners.update({o["name"]: o for o in objects.values() if o.get("isa") == "PBXNativeTarget" and o.get("name") in modules})
    for name, owner in owners.items():
        configs = objects[owner["buildConfigurationList"]]["buildConfigurations"]
        release = [objects[identifier]["buildSettings"] for identifier in configs if objects[identifier]["name"] == "Release"]
        if len(release) != 1:
            raise CoverageError(f"No unique Release configuration for {name}")
        result[name] = release[0]
    return result


def parse_lcov(contents, source_root, manifest):
    """Union repeated records and instances; never count execution counts as line totals."""
    source_root = source_root.resolve()
    files = {}
    current = None
    for line in contents.split("\n"):
        if line.startswith("SF:"):
            path = Path(line[3:])
            if not path.is_absolute():
                raise CoverageError(f"LCOV source path must be absolute: {path}")
            try:
                relative = path.resolve().relative_to(source_root).as_posix()
            except ValueError:
                current = None  # SDK/generated files outside the exact build root.
                continue
            if relative not in manifest["files"]:
                if relative.startswith("Sources/"):
                    raise CoverageError(f"Unaccounted coverage source: {relative}")
                current = None  # Tests and generated sources are not shipped.
                continue
            current = files.setdefault(relative, {})
        elif line.startswith("DA:") and current is not None:
            fields = line[3:].split(",")
            number, count = int(fields[0]), int(fields[1])
            if number < 1 or count < 0:
                raise CoverageError("Invalid LCOV line/count")
            current[str(number)] = current.get(str(number), False) or count > 0
        elif line == "end_of_record":
            current = None
    return files


def normalize(lcov, source_root, manifest, lane):
    for path, value in manifest["files"].items():
        if hashlib.sha256((source_root / path).read_bytes()).hexdigest() != value["sha256"]:
            raise CoverageError(f"Source changed during collection: {path}")
    return {"schema": 1, "lane": lane, "inventory": manifest,
            "files": parse_lcov(lcov, source_root, manifest)}


def merge_reports(manifest, reports):
    merged = {}
    for report in reports:
        if report.get("schema") != 1 or report.get("inventory") != manifest:
            raise CoverageError("Incompatible report: source hashes, source inventory, build inputs or configuration differ")
        for path, lines in report["files"].items():
            if path not in manifest["files"]:
                raise CoverageError(f"Unknown report source: {path}")
            if manifest["files"][path].get("excluded"):
                continue
            if not lines:
                raise CoverageError(f"No executable-line mapping for shipped source: {path}")
            dest = merged.setdefault(path, {})
            for number, covered in lines.items():
                if not number.isdigit() or int(number) < 1 or type(covered) is not bool:
                    raise CoverageError("Invalid normalized executable line")
                dest[number] = dest.get(number, False) or covered
    missing = sorted(p for p, v in manifest["files"].items() if not v.get("excluded") and p not in merged)
    if missing:
        raise CoverageError("Missing shipped source coverage: " + ", ".join(missing))
    return merged


def _git_quoted_path(value):
    """Decode Git's C-quoted unified-diff path into a filesystem path."""
    if not value.startswith('"'):
        raise CoverageError("Malformed quoted unified diff path")
    encoded = bytearray()
    index = 1
    while index < len(value):
        char = value[index]
        if char == '"':
            suffix = value[index + 1:]
            if suffix and not suffix.startswith("\t"):
                raise CoverageError("Malformed quoted unified diff path suffix")
            return os.fsdecode(bytes(encoded))
        if char != "\\":
            encoded.extend(char.encode("utf-8"))
            index += 1
            continue
        index += 1
        if index >= len(value):
            raise CoverageError("Malformed escape in quoted unified diff path")
        escaped = value[index]
        controls = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13}
        if escaped in controls:
            encoded.append(controls[escaped])
            index += 1
        elif escaped in {'"', "\\"}:
            encoded.extend(escaped.encode("ascii"))
            index += 1
        elif escaped in "01234567":
            end = index
            while end < min(index + 3, len(value)) and value[end] in "01234567":
                end += 1
            encoded.append(int(value[index:end], 8))
            index = end
        else:
            raise CoverageError("Unknown escape in quoted unified diff path")
    raise CoverageError("Unterminated quoted unified diff path")


def _unified_diff_path(header):
    if not header.startswith("+++ "):
        return None
    value = header[4:]
    if value == "/dev/null":
        return None
    if value.startswith('"'):
        value = _git_quoted_path(value)
    else:
        # Unified diff permits a tab-delimited timestamp after the path. Git
        # quotes control characters in paths, so a tab here is the delimiter.
        value = value.split("\t", 1)[0]
    if not value.startswith("b/"):
        return None
    return value[2:]


def changed_lines(diff):
    result = defaultdict(set)
    path = None
    in_hunk = False
    for line in diff.split("\n"):
        if line.startswith("diff --git "):
            path = None
            in_hunk = False
        elif not in_hunk and line.startswith("+++ "):
            path = _unified_diff_path(line)
        elif line.startswith("@@ ") and path:
            match = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
            if not match:
                raise CoverageError("Malformed unified diff hunk")
            start, count = int(match[1]), int(match[2] or 1)
            result[path].update(range(start, start + count))
            in_hunk = True
        elif line.startswith("@@ "):
            in_hunk = True
    return result


def summarize(manifest, merged, changed=None):
    totals = defaultdict(lambda: {"covered": 0, "total": 0})
    for path, lines in merged.items():
        module = manifest["files"][path]["module"]
        for number, covered in lines.items():
            if changed is None or int(number) in changed.get(path, set()):
                totals[module]["total"] += 1
                totals[module]["covered"] += covered
    aggregate = {"covered": sum(v["covered"] for v in totals.values()), "total": sum(v["total"] for v in totals.values())}
    for value in [*totals.values(), aggregate]:
        value["percent"] = 100 * value["covered"] / value["total"] if value["total"] else None
    return {"modules": dict(totals), "aggregate": aggregate}


def passes(summary, threshold=95):
    value = summary["aggregate"]
    return value["total"] == 0 or value["covered"] * 100 >= threshold * value["total"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    commands = parser.add_subparsers(dest="command", required=True)
    inv = commands.add_parser("inventory")
    inv.add_argument("--output", type=Path, required=True)
    collect = commands.add_parser("normalize")
    collect.add_argument("--inventory", type=Path, required=True)
    collect.add_argument("--lcov", type=Path, required=True)
    collect.add_argument("--lane", choices=["package", "hosted", "native"], required=True)
    collect.add_argument("--output", type=Path, required=True)
    report = commands.add_parser("report")
    report.add_argument("--reports", type=Path, nargs="+", required=True)
    report.add_argument("--base", help="Git base revision; includes committed, staged, unstaged and untracked Swift changes")
    report.add_argument("--whole", action="store_true", help="Also enforce final whole-source 95%% gate")
    report.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    try:
        if args.command == "inventory":
            save_json(args.output, current_inventory(root))
        elif args.command == "normalize":
            save_json(args.output, normalize(args.lcov.read_text(), root, read_json(args.inventory), args.lane))
        else:
            if not args.base and not args.whole:
                raise CoverageError("Choose --base for incremental gate, --whole for final gate, or both")
            manifest = current_inventory(root)
            merged = merge_reports(manifest, [read_json(p) for p in args.reports])
            result = {"whole": summarize(manifest, merged)}
            if args.base:
                diff = command(["git", "-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-renames", "--unified=0", args.base, "--", "Sources"], cwd=root)
                changed = changed_lines(diff)
                untracked = command(["git", "ls-files", "--others", "--exclude-standard", "-z", "--", "Sources"], cwd=root)
                for path in filter(None, untracked.split("\0")):
                    if path in manifest["files"]:
                        changed[path].update(int(n) for n in merged.get(path, {}))
                result["incremental"] = summarize(manifest, merged, changed)
            if args.output:
                save_json(args.output, result)
            print(json.dumps(result, indent=2))
            return 0 if ((not args.whole or passes(result["whole"])) and (not args.base or passes(result["incremental"]))) else 1
    except (CoverageError, ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"Coverage invalid: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
