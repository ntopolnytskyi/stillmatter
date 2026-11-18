#!/usr/bin/env python3
"""Cached developer tests and fresh, authoritative full coverage evidence."""
import argparse
import hashlib
from datetime import datetime, timezone
import json
import platform
import re
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
FAST_FILTER = "StillmatterPresentationTests|MeetingArtifactEdgeCaseTests|MeetingActionReviewTests|MeetingNoteTodoBridgeTests|TodoItemsTests"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=["fast", "package", "hosted", "e2e", "controls", "full"])
    parser.add_argument("--filter", help="SwiftPM regex, or Xcode class/method (without target prefix)")
    parser.add_argument("--output", type=Path, help="Fresh evidence directory; existing directories are rejected")
    parser.add_argument("--base", default="HEAD", help="Coverage comparison revision (full profile)")
    args = parser.parse_args(argv)
    if args.profile == "full" and args.filter:
        parser.error("full evidence cannot be filtered")
    output = (args.output or ROOT / ".build/test-runs" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")).resolve()
    output.mkdir(parents=True, exist_ok=False)
    evidence = {"profile": args.profile, "filter": args.filter, "started": datetime.now(timezone.utc).isoformat(),
                "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "machine": platform.platform(),
                "test_sources_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                        for path in sorted((ROOT / "Tests").rglob("*.swift"))},
                "commands": [], "status": "running"}
    started = time.monotonic()

    def save():
        (output / "execution.json").write_text(json.dumps(evidence, indent=2) + "\n")

    def run(command, name, check=True):
        print("Running: " + " ".join(map(str, command)), flush=True)
        step = {"command": list(map(str, command)), "log": name + ".log"}
        evidence["commands"].append(step)
        save()
        tick = time.monotonic()
        with (output / step["log"]).open("w") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        step.update(exit_code=result.returncode, seconds=round(time.monotonic() - tick, 3))
        save()
        if result.returncode and check:
            raise RuntimeError(f"{name} exited {result.returncode}; see {output / step['log']}")
        return result.returncode

    try:
        save()
        for tool, command in [("swift", ["swift", "--version"]), ("xcode", ["xcodebuild", "-version"])]:
            evidence[tool] = subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()
        if args.profile in ("fast", "package"):
            command = ["swift", "test"]
            selection = args.filter or (FAST_FILTER if args.profile == "fast" else None)
            if selection:
                command += ["--filter", selection]
            test_exit = run(command, "tests", check=False)
        elif args.profile == "full":
            # The coverage collector intentionally uses fresh scratch/DerivedData roots.
            # Never substitute cached developer artifacts or focused execution here.
            reports = []
            failures = []
            for lane, controls in [("package", False), ("hosted", False), ("native", False), ("native", True)]:
                name = "controls" if controls else lane
                destination = output / name
                command = [sys.executable, "scripts/run-coverage.py", lane, "--output", str(destination)]
                if controls:
                    command += ["--controls"]
                try:
                    run(command, name)
                    reports.append(str(destination / "report.json"))
                except RuntimeError as error:
                    failures.append(str(error))
            if failures:
                raise RuntimeError("; ".join(failures) + "; coverage union unavailable")
            run([sys.executable, "scripts/coverage.py", "report", "--reports", *reports,
                 "--base", args.base, "--whole", "--output", str(output / "coverage-gate.json")], "coverage-gate")
        else:
            if platform.system() != "Darwin":
                evidence["status"] = "unavailable"
                raise RuntimeError("Hosted and native tests require macOS/Xcode; E2E also requires an unlocked GUI with automation permission")
            scheme, target = {"e2e": ("Stillmatter", "StillmatterUITests"),
                              "hosted": ("StillmatterHostedTests", "StillmatterHostedTests"),
                              "controls": ("StillmatterControlsUITests", "StillmatterControlsUITests")}[args.profile]
            if args.profile in ("e2e", "controls"):
                print("Requires an unlocked macOS GUI and Xcode automation permission. Uses foreground input.", flush=True)
            command = ["xcodebuild", "test", "-project", "Stillmatter.xcodeproj", "-scheme", scheme,
                       "-configuration", "Release", "-destination", "platform=macOS",
                       "-derivedDataPath", str(ROOT / ".build/test-derived"),
                       "-resultBundlePath", str(output / "results.xcresult"),
                       "-enableCodeCoverage", "NO", "-parallel-testing-enabled", "NO", "ONLY_ACTIVE_ARCH=YES"]
            if args.filter:
                command += [f"-only-testing:{target}/{args.filter}"]
            test_exit = run(command, "tests", check=False)
            run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(output / "results.xcresult")], "summary")
            summary = json.loads((output / "summary.log").read_text())
            evidence["tests"] = {k: summary[k] for k in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
            if test_exit or summary["passedTests"] == 0 or summary["failedTests"]:
                raise RuntimeError("No passing non-skipped tests, or failures; this is not passing evidence")
        if args.profile in ("fast", "package"):
            log = (output / "tests.log").read_text()
            outcomes = re.findall(r"Test Case .* (passed|failed|skipped) \(", log)
            evidence["tests"] = {"total": len(outcomes), **{outcome: outcomes.count(outcome) for outcome in ("passed", "failed", "skipped")}}
            if test_exit:
                raise RuntimeError(f"SwiftPM exited {test_exit}; see {output / 'tests.log'}")
            # Reuse the coverage collector's strict XCTest count parser without instrumentation.
            import importlib.util
            spec = importlib.util.spec_from_file_location("collector", ROOT / "scripts/run-coverage.py")
            collector = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(collector)
            try:
                collector.package_counts(log)
            except collector.coverage.CoverageError as error:
                raise RuntimeError(str(error)) from error
        evidence["status"] = "passed"
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.CalledProcessError) as error:
        if evidence["status"] != "unavailable":
            evidence["status"] = "failed"
        evidence["error"] = str(error)
        print(str(error), file=sys.stderr)
    finally:
        evidence["seconds"] = round(time.monotonic() - started, 3)
        save()
        print(f"{evidence['status']}: {output} ({evidence['seconds']}s)", flush=True)
    return 0 if evidence["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
