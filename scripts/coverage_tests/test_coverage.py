import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load("coverage_runner", "run-coverage.py")
gate = runner.coverage


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="stillmatter-coverage-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.core = "Sources/StillmatterCore/Store.swift"
        self.app = "Sources/Stillmatter/Window.swift"
        for path in [self.core, self.app]:
            destination = self.root / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text("func example() {}\n")
        self.package = {"products": [{"name": "Stillmatter", "targets": ["Stillmatter"]}], "targets": [
            {"name": "Stillmatter", "path": "Sources/Stillmatter", "sources": ["Window.swift"], "target_dependencies": ["StillmatterCore"]},
            {"name": "StillmatterCore", "path": "Sources/StillmatterCore", "sources": ["Store.swift"]},
            {"name": "Tests", "type": "test", "path": "Tests", "sources": ["Example.swift"]}]}
        self.project = {"objects": {"app": {"isa": "PBXNativeTarget", "name": "Stillmatter", "fileSystemSynchronizedGroups": ["app-group"]},
                                    "core": {"isa": "PBXNativeTarget", "name": "StillmatterCore", "fileSystemSynchronizedGroups": ["core-group"]},
                                    "app-group": {"path": "Sources/Stillmatter"}, "core-group": {"path": "Sources/StillmatterCore"}}}
        self.manifest = self.inventory()

    def inventory(self, exclusions=None):
        return gate.inventory(self.root, self.package, self.project, exclusions or {})

    def lcov(self, path, lines):
        return f"SF:{self.root / path}\n" + "".join(f"DA:{number},{count}\n" for number, count in lines.items()) + "end_of_record\n"

    def report(self, core=None, app=None, lane="package"):
        contents = self.lcov(self.core, core or {1: 1})
        if app is not None:
            contents += self.lcov(self.app, app)
        return gate.normalize(contents, self.root, self.manifest, lane)

    def test_inventory_includes_every_shipping_target_and_not_tests(self):
        self.assertEqual(set(self.manifest["files"]), {self.core, self.app})
        self.assertEqual(self.manifest["files"][self.app]["module"], "Stillmatter")

    def test_inventory_rejects_unaccounted_source(self):
        (self.root / "Sources/Stillmatter/New.swift").write_text("func new() {}")
        with self.assertRaisesRegex(gate.CoverageError, "inventory differs"):
            self.inventory()

    def test_inventory_rejects_target_source_mismatch(self):
        self.project["objects"]["app-group"]["path"] = "Sources/StillmatterCore"
        with self.assertRaisesRegex(gate.CoverageError, "inventory differs"):
            self.inventory()

    def test_inventory_rejects_unknown_dependency(self):
        self.package["targets"][0]["target_dependencies"].append("Missing")
        with self.assertRaisesRegex(gate.CoverageError, "Unaccounted shipping dependency"):
            self.inventory()

    def test_inventory_rejects_new_external_dependencies_for_review(self):
        self.package["dependencies"] = [{"name": "ThirdParty"}]
        with self.assertRaisesRegex(gate.CoverageError, "third-party"):
            self.inventory()

    def test_inventory_rejects_synchronized_group_exceptions_for_review(self):
        self.project["objects"]["app-group"]["exceptions"] = ["exception"]
        self.project["objects"]["exception"] = {"target": "app"}
        with self.assertRaisesRegex(gate.CoverageError, "source exclusions"):
            self.inventory()

    def test_inventory_ignores_shared_group_exceptions_for_nonshipping_host(self):
        self.project["objects"]["app-group"]["exceptions"] = ["exception"]
        self.project["objects"]["exception"] = {"target": "host", "membershipExceptions": ["Window.swift"]}
        self.assertEqual(self.inventory(), self.manifest)

    def test_inventory_rejects_explicit_source_membership_for_review(self):
        self.project["objects"]["app"]["buildPhases"] = ["phase"]
        self.project["objects"]["phase"] = {"isa": "PBXSourcesBuildPhase", "files": ["extra"]}
        with self.assertRaisesRegex(gate.CoverageError, "explicit Xcode source"):
            self.inventory()

    def test_exclusions_require_exact_path_reason_and_reviewed_hash(self):
        exclusion = {"reason": "Non-shipped validation", "sha256": self.manifest["files"][self.app]["sha256"]}
        manifest = self.inventory({self.app: exclusion})
        self.assertEqual(manifest["files"][self.app]["excluded"], "Non-shipped validation")
        exclusion["sha256"] = "old"
        with self.assertRaisesRegex(gate.CoverageError, "Excluded source changed"):
            self.inventory({self.app: exclusion})
        with self.assertRaisesRegex(gate.CoverageError, "Stale coverage exclusion"):
            self.inventory({"Sources/Gone.swift": exclusion})

    def test_duplicate_lcov_records_union_lines_without_double_counting(self):
        report = gate.normalize(self.lcov(self.core, {1: 1, 2: 0}) + self.lcov(self.core, {1: 0, 2: 4}) + self.lcov(self.app, {1: 1}), self.root, self.manifest, "package")
        merged = gate.merge_reports(self.manifest, [report, report])
        self.assertEqual(gate.summarize(self.manifest, merged)["aggregate"], {"covered": 3, "total": 3, "percent": 100})

    def test_package_hosted_native_reports_union_by_source_location(self):
        package = self.report({1: 1, 2: 0})
        hosted = self.report({1: 0, 2: 1}, {3: 0, 4: 1}, "hosted")
        native = self.report({1: 1, 2: 0}, {3: 1, 4: 0}, "native")
        summary = gate.summarize(self.manifest, gate.merge_reports(self.manifest, [package, hosted, native]))
        self.assertEqual(summary["aggregate"]["covered"], 4)
        self.assertEqual(summary["aggregate"]["total"], 4)
        self.assertEqual(set(summary["modules"]), {"Stillmatter", "StillmatterCore"})

    def test_missing_app_file_fails_even_with_perfect_package_coverage(self):
        with self.assertRaisesRegex(gate.CoverageError, "Missing shipped source coverage.*Window.swift"):
            gate.merge_reports(self.manifest, [self.report()])

    def test_incremental_only_allows_unmodified_source_gaps_but_requires_changed_files(self):
        report = self.report()
        merged = gate.merge_reports(self.manifest, [report], require_complete=False)
        gate.require_changed_sources_covered(self.manifest, merged, {self.core: {1}})
        self.assertTrue(gate.passes(gate.summarize(self.manifest, merged, {self.core: {1}})))
        with self.assertRaisesRegex(gate.CoverageError, "Missing changed shipped source coverage.*Window.swift"):
            gate.require_changed_sources_covered(self.manifest, merged, {self.app: {1}})
        with self.assertRaisesRegex(gate.CoverageError, "Missing shipped source coverage.*Window.swift"):
            gate.merge_reports(self.manifest, [report])

    def test_empty_file_record_cannot_launder_missing_instrumentation(self):
        report = self.report(app={1: 1})
        report["files"][self.app] = {}
        with self.assertRaisesRegex(gate.CoverageError, "No executable-line mapping"):
            gate.merge_reports(self.manifest, [report])

    def test_missing_file_cannot_be_laundered_with_reduced_inventory(self):
        report = self.report(app={1: 1})
        del report["inventory"]["files"][self.app]
        current = self.inventory()
        with self.assertRaisesRegex(gate.CoverageError, "Incompatible report"):
            gate.merge_reports(current, [report])

    def test_source_edit_after_collection_invalidates_old_reports(self):
        report = self.report(app={1: 1})
        (self.root / self.app).write_text("func changed() {}")
        with self.assertRaisesRegex(gate.CoverageError, "Incompatible report"):
            gate.merge_reports(self.inventory(), [report])

    def test_source_edit_during_collection_fails(self):
        (self.root / self.app).write_text("func changed() {}")
        with self.assertRaisesRegex(gate.CoverageError, "Source changed during collection"):
            self.report(app={1: 1})

    def test_configuration_mismatch_invalidates_reports(self):
        report = self.report(app={1: 1})
        report["inventory"] = copy.deepcopy(report["inventory"])
        report["inventory"]["configuration"] = "debug"
        with self.assertRaisesRegex(gate.CoverageError, "Incompatible report"):
            gate.merge_reports(self.manifest, [report])

    def test_shipping_build_flags_are_fingerprinted_without_test_target_noise(self):
        project = {"rootObject": "project", "objects": {
            "project": {"buildConfigurationList": "configs"},
            "app": {"isa": "PBXNativeTarget", "name": "Stillmatter", "buildConfigurationList": "configs"},
            "host": {"isa": "PBXNativeTarget", "name": "TestHost", "buildConfigurationList": "test-configs"},
            "configs": {"buildConfigurations": ["release"]},
            "release": {"name": "Release", "buildSettings": {"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "SWIFT_PACKAGE"}},
            "test-configs": {"buildConfigurations": ["test-release"]},
            "test-release": {"name": "Release", "buildSettings": {"OTHER_SWIFT_FLAGS": "TEST_ONLY"}}}}
        before = copy.deepcopy(gate.shipping_release_settings(project, {"Stillmatter"}))
        project["objects"]["test-release"]["buildSettings"]["OTHER_SWIFT_FLAGS"] = "CHANGED_TEST_ONLY"
        self.assertEqual(gate.shipping_release_settings(project, {"Stillmatter"}), before)
        project["objects"]["release"]["buildSettings"]["OTHER_SWIFT_FLAGS"] = "-DNEW_SHIPPING_FLAG"
        self.assertNotEqual(gate.shipping_release_settings(project, {"Stillmatter"}), before)

    def test_toolchain_or_package_fingerprint_mismatch_invalidates_report(self):
        expected = copy.deepcopy(self.manifest)
        expected["build_inputs"] = {"swift": "current", "package_sha256": "current"}
        report = self.report(app={1: 1})
        report["inventory"]["build_inputs"] = {"swift": "old", "package_sha256": "old"}
        with self.assertRaisesRegex(gate.CoverageError, "Incompatible report"):
            gate.merge_reports(expected, [report])

    def test_worktree_paths_are_normalized_using_only_explicit_root(self):
        with tempfile.TemporaryDirectory(prefix="stillmatter-other-worktree-") as other:
            other_root = Path(other).resolve()
            for path in self.manifest["files"]:
                destination = other_root / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((self.root / path).read_bytes())
            contents = self.lcov(self.core, {1: 1}).replace(str(self.root), str(other_root))
            report = gate.normalize(contents, other_root, self.manifest, "package")
            self.assertEqual(set(report["files"]), {self.core})
            wrong_root = gate.normalize(contents, self.root, self.manifest, "package")
            self.assertEqual(wrong_root["files"], {})

    def test_generated_and_test_files_do_not_inflate_production_coverage(self):
        contents = self.lcov("Tests/Tests.swift", {1: 100}) + self.lcov(".build/generated.swift", {2: 100}) + self.lcov(self.app, {1: 0}) + self.lcov(self.core, {1: 0})
        report = gate.normalize(contents, self.root, self.manifest, "native")
        self.assertEqual(gate.summarize(self.manifest, gate.merge_reports(self.manifest, [report]))["aggregate"]["covered"], 0)

    def test_unknown_production_coverage_source_fails(self):
        with self.assertRaisesRegex(gate.CoverageError, "Unaccounted coverage source"):
            gate.normalize(self.lcov("Sources/Unknown.swift", {1: 1}), self.root, self.manifest, "package")

    def test_invalid_line_and_count_fail(self):
        for number, count in [(0, 1), (1, -1)]:
            with self.subTest(number=number, count=count):
                with self.assertRaisesRegex(gate.CoverageError, "Invalid LCOV"):
                    gate.normalize(self.lcov(self.core, {number: count}), self.root, self.manifest, "package")

    def test_exact_95_boundary_and_no_rounding_up(self):
        covered = {str(n): n <= 95 for n in range(1, 101)}
        summary = gate.summarize(self.manifest, {self.core: covered})
        self.assertTrue(gate.passes(summary))
        covered["95"] = False
        self.assertFalse(gate.passes(gate.summarize(self.manifest, {self.core: covered})))

    def test_incremental_gate_ignores_unchanged_coverage_debt(self):
        merged = {self.core: {"1": False, "2": True}, self.app: {"1": True}}
        self.assertFalse(gate.passes(gate.summarize(self.manifest, merged)))
        self.assertTrue(gate.passes(gate.summarize(self.manifest, merged, {self.core: {2}})))

    def test_incremental_gate_zero_changed_executable_lines_is_not_whole_coverage(self):
        merged = {self.core: {"1": False}, self.app: {"1": False}}
        self.assertTrue(gate.passes(gate.summarize(self.manifest, merged, {})))
        self.assertFalse(gate.passes(gate.summarize(self.manifest, merged)))

    def test_changed_lines_support_added_deleted_unicode_and_space_paths(self):
        diff = "diff --git a/Sources/Код Файл.swift b/Sources/Код Файл.swift\n+++ b/Sources/Код Файл.swift\n@@ -1,2 +1,3 @@\n+new\ndiff --git a/Sources/Deleted.swift b/Sources/Deleted.swift\n+++ b/Sources/Deleted.swift\n@@ -1,2 +0,0 @@\ndiff --git a/Sources/Single.swift b/Sources/Single.swift\n+++ b/Sources/Single.swift\n@@ -0,0 +4 @@\n+new\n"
        lines = gate.changed_lines(diff)
        self.assertEqual(lines["Sources/Код Файл.swift"], {1, 2, 3})
        self.assertEqual(lines["Sources/Deleted.swift"], set())
        self.assertEqual(lines["Sources/Single.swift"], {4})

    def test_changed_lines_parse_git_generated_paths_with_spaces_and_c_escapes(self):
        repository = self.root / "git-diff"
        repository.mkdir()
        paths = [
            "Sources/Space Name.swift",
            'Sources/Quoted"Name.swift',
            "Sources/Back\\slash.swift",
            "Sources/Tab\tName.swift",
            "Sources/New\nLine.swift",
            "Sources/Код.swift",
            "Sources/Line\u2028Separator.swift",
            "Sources/Paragraph\u2029Separator.swift",
        ]
        for path in paths:
            destination = repository / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text("before\n")
        subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
        subprocess.run(["git", "config", "user.email", "coverage@example.test"], cwd=repository, check=True)
        subprocess.run(["git", "config", "user.name", "Coverage Test"], cwd=repository, check=True)
        subprocess.run(["git", "add", "--", "Sources"], cwd=repository, check=True)
        subprocess.run(["git", "commit", "-qm", "baseline"], cwd=repository, check=True)
        for path in paths:
            (repository / path).write_text("after\n")

        diff = gate.command([
            "git", "-c", "core.quotePath=false", "diff", "--no-ext-diff",
            "--no-renames", "--unified=0", "HEAD", "--", "Sources",
        ], cwd=repository)
        lines = gate.changed_lines(diff)
        self.assertEqual(set(lines), set(paths))
        self.assertTrue(all(value == {1} for value in lines.values()))
        synthetic_manifest = {"files": {path: {"module": "Stillmatter"} for path in paths}}
        uncovered = {path: {"1": False} for path in paths}
        changed_summary = gate.summarize(synthetic_manifest, uncovered, lines)
        self.assertEqual(changed_summary["aggregate"]["total"], len(paths))
        self.assertFalse(gate.passes(changed_summary))

    def test_lcov_records_preserve_unicode_line_separator_filenames(self):
        paths = ["Sources/Line\u2028Separator.swift", "Sources/Paragraph\u2029Separator.swift"]
        manifest = {"files": {}}
        contents = ""
        for path in paths:
            source = self.root / path
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("func example() {}\n")
            manifest["files"][path] = {"module": "Stillmatter"}
            contents += f"SF:{source}\nDA:1,0\nend_of_record\n"
        self.assertEqual(gate.parse_lcov(contents, self.root, manifest), {path: {"1": False} for path in paths})

    def test_changed_lines_do_not_treat_added_multiline_string_as_file_header(self):
        repository = self.root / "git-hunk"
        source = repository / "Sources/Real.swift"
        source.parent.mkdir(parents=True)
        source.write_text("""let text = \"\"\"\nfirst\nthird\n\"\"\"\nlet one = 1\nlet two = 2\nlet three = 3\nlet four = 4\nlet five = 5\nlet six = 6\nlet seven = 7\nlet eight = 8\nlet nine = 9\nlet ten = 10\nlet target = 0\n""")
        subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
        subprocess.run(["git", "config", "user.email", "coverage@example.test"], cwd=repository, check=True)
        subprocess.run(["git", "config", "user.name", "Coverage Test"], cwd=repository, check=True)
        subprocess.run(["git", "add", "--", "Sources/Real.swift"], cwd=repository, check=True)
        subprocess.run(["git", "commit", "-qm", "baseline"], cwd=repository, check=True)
        source.write_text("""let text = \"\"\"\nfirst\n++ b/Sources/Fake.swift\nthird\n\"\"\"\nlet one = 1\nlet two = 2\nlet three = 3\nlet four = 4\nlet five = 5\nlet six = 6\nlet seven = 7\nlet eight = 8\nlet nine = 9\nlet ten = 10\nlet target = 1\n""")

        diff = gate.command([
            "git", "-c", "core.quotePath=false", "diff", "--no-ext-diff",
            "--no-renames", "--unified=0", "HEAD", "--", "Sources",
        ], cwd=repository)
        lines = gate.changed_lines(diff)
        self.assertEqual(set(lines), {"Sources/Real.swift"})
        self.assertGreater(len(lines["Sources/Real.swift"]), 1)
        synthetic_manifest = {"files": {"Sources/Real.swift": {"module": "Stillmatter"}}}
        uncovered = {"Sources/Real.swift": {str(number): False for number in lines["Sources/Real.swift"]}}
        self.assertFalse(gate.passes(gate.summarize(synthetic_manifest, uncovered, lines)))

    def test_changed_lines_ignore_git_unified_diff_timestamp_separator(self):
        source = self.root / "Sources/Space Name.swift"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text("func example() {}\n")
        diff = subprocess.run(
            ["git", "diff", "--no-index", "--text", "--unified=0", "/dev/null", "Sources/Space Name.swift"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, cwd=self.root,
        ).stdout
        self.assertIn("+++ ", diff)
        path = gate.changed_lines(diff)
        self.assertEqual(path, {"Sources/Space Name.swift": {1}})

    def test_package_execution_requires_non_skipped_tests_and_reports_skips(self):
        self.assertEqual(runner.package_counts("Executed 303 tests, with 4 tests skipped and 0 failures"), {"total": 303, "skipped": 4, "failed": 0})
        for log in ["Build succeeded", "Executed 0 tests, with 0 failures", "Executed 4 tests, with 4 tests skipped and 0 failures", "Executed 1 test, with 1 failure"]:
            with self.subTest(log=log):
                with self.assertRaises(gate.CoverageError):
                    runner.package_counts(log)

    def test_native_execution_requires_real_passes_not_a_build_or_skipped_run(self):
        summary = {"totalTestCount": 2, "passedTests": 1, "skippedTests": 1, "failedTests": 0, "result": "Passed"}
        self.assertEqual(runner.xcode_counts(summary), {"total": 2, "skipped": 1, "failed": 0})
        summary["passedTests"] = 0
        with self.assertRaises(gate.CoverageError):
            runner.xcode_counts(summary)

    def test_collector_refuses_existing_output_without_overwriting_evidence(self):
        output = self.root / "existing"
        output.mkdir()
        evidence = output / "execution.json"
        evidence.write_text('{"status": "passed"}\n')
        self.assertEqual(runner.main(["package", "--root", str(self.root), "--output", str(output)]), 1)
        self.assertEqual(evidence.read_text(), '{"status": "passed"}\n')


if __name__ == "__main__":
    unittest.main()
