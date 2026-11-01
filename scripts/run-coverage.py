#!/usr/bin/env python3
"""Execute an isolated package, app-hosted, or native UI coverage lane."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

spec = importlib.util.spec_from_file_location("coverage_gate", Path(__file__).with_name("coverage.py"))
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


def run(args, log, cwd):
    print("Running " + " ".join(str(a) for a in args), flush=True)
    with log.open("w") as stream:
        subprocess.run(args, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT, check=True)


def package_counts(log):
    matches = re.findall(r"Executed (\d+) tests?, (?:with )?(?:(\d+) tests? skipped and )?(\d+) failures?", log)
    if not matches:
        raise coverage.CoverageError("No XCTest execution summary; a build or an empty test run is not passing evidence")
    total, skipped, failures = matches[-1]
    counts = {"total": int(total), "skipped": int(skipped or 0), "failed": int(failures)}
    if counts["total"] <= counts["skipped"] or counts["failed"]:
        raise coverage.CoverageError(f"No successful non-skipped package tests: {counts}")
    return counts


def xcode_counts(summary):
    counts = {"total": summary["totalTestCount"], "skipped": summary["skippedTests"], "failed": summary["failedTests"]}
    if summary["passedTests"] <= 0 or counts["failed"] or summary["result"] != "Passed":
        raise coverage.CoverageError(f"Native tests did not pass: {counts}")
    return counts


def export_lcov(profile, objects, architecture=None):
    args = ["xcrun", "llvm-cov", "export", "-format=lcov", f"-instr-profile={profile}", str(objects[0])]
    if architecture:
        args += [f"-arch={architecture}"]
    for binary in objects[1:]:
        args += ["-object", str(binary)]
    return coverage.command(args)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lane", choices=["package", "native", "hosted"])
    parser.add_argument("--output", type=Path, required=True, help="New output directory; never reuses old profiles")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--only-testing", action="append", default=[])
    args = parser.parse_args(argv)
    root, output = args.root.resolve(), args.output.resolve()
    status = {"lane": args.lane, "status": "not-run"}
    created = False
    try:
        output.mkdir(parents=True, exist_ok=False)
        created = True
        manifest = coverage.current_inventory(root)
        coverage.save_json(output / "inventory.json", manifest)
        status["status"] = "running"
        coverage.save_json(output / "execution.json", status)
        if args.lane == "package":
            if args.only_testing:
                raise coverage.CoverageError("--only-testing is Xcode-only; package lane executes the complete suite")
            scratch = output / "package"
            run(["swift", "test", "--package-path", str(root), "--scratch-path", str(scratch), "--configuration", "release", "--enable-code-coverage", "-Xswiftc", "-Onone"], output / "tests.log", root)
            status["tests"] = package_counts((output / "tests.log").read_text())
            binary_dir = Path(coverage.command(["swift", "build", "--package-path", str(root), "--scratch-path", str(scratch), "--configuration", "release", "--show-bin-path"]).strip())
            binary = binary_dir / "StillmatterPackageTests.xctest/Contents/MacOS/StillmatterPackageTests"
            lcov = export_lcov(binary_dir / "codecov/default.profdata", [binary])
        else:
            scheme = "Stillmatter" if args.lane == "native" else "StillmatterHostedTests"
            bundle = output / "results.xcresult"
            derived = output / "derived"
            test_args = ["xcodebuild", "test", "-project", str(root / "Stillmatter.xcodeproj"), "-scheme", scheme,
                         "-configuration", "Release", "-destination", "platform=macOS", "-derivedDataPath", str(derived),
                         "-resultBundlePath", str(bundle), "-enableCodeCoverage", "YES", "SWIFT_OPTIMIZATION_LEVEL=-Onone"]
            test_args += [f"-only-testing:{name}" for name in args.only_testing]
            run(test_args, output / "tests.log", root)
            summary = json.loads(coverage.command(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)]))
            coverage.save_json(output / "test-summary.json", summary)
            status["tests"] = xcode_counts(summary)
            profiles = sorted(derived.glob("Build/ProfileData/*/Coverage.profdata"))
            if not profiles:
                raise coverage.CoverageError("Tests produced no instrumented profile")
            product = "Stillmatter" if args.lane == "native" else "StillmatterHostedTestHost"
            macos = derived / f"Build/Products/Release/{product}.app/Contents/MacOS"
            binaries = [macos / product]
            dylib = macos / f"{product}.debug.dylib"
            if dylib.exists():
                binaries.append(dylib)
            # Shared modules are static libraries linked into the app/host, not separate denominators.
            architectures = {entry["device"]["architecture"] for entry in summary["devicesAndConfigurations"]}
            if len(architectures) != 1:
                raise coverage.CoverageError("Expected one executed macOS architecture per native coverage lane")
            architecture = architectures.pop()
            lcov = "\n".join(export_lcov(profile, binaries, architecture) for profile in profiles)
        (output / "coverage.lcov").write_text(lcov)
        if coverage.current_inventory(root) != manifest:
            raise coverage.CoverageError("Source inventory or policy changed during execution")
        report = coverage.normalize(lcov, root, manifest, args.lane)
        coverage.save_json(output / "report.json", report)
        status["status"] = "passed"
        coverage.save_json(output / "execution.json", status)
        print(json.dumps(status, indent=2))
        return 0
    except (coverage.CoverageError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        status.update(status="failed", error=str(error))
        if created:
            coverage.save_json(output / "execution.json", status)
        print(f"Coverage lane failed: {error}. See {output / 'tests.log'}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
