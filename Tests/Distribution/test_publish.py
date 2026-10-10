"""Offline publication, workflow, and command checks using local Git fixtures."""

import contextlib
import copy
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import release

REPOSITORY = "grahamannett/aviary-swift"
VERSION = "0.1.2"
TAG = f"v{VERSION}"
VERSION_FILES = ["Sources/AviaryCLI/AviaryRoot.swift", "mise.test.toml"]
TAP_REPOSITORY = "grahamannett/homebrew-tap"
TAP_URL = f"https://github.com/{TAP_REPOSITORY}.git"


def rest_release(tag="v0.1.2"):
    return {
        "tag_name": tag,
        "draft": False,
        "prerelease": False,
        "html_url": f"https://github.com/{REPOSITORY}/releases/tag/{tag}",
        "assets": [{"name": "aviary.rb", "size": 100}],
    }


class CommandTests(unittest.TestCase):
    def test_execution_captures_output_and_has_no_interactive_input(self):
        with tempfile.TemporaryDirectory(prefix="aviary-command-test-") as directory:
            result = release.run_command(
                [
                    sys.executable,
                    "-c",
                    "import sys; print(repr(sys.stdin.read())); "
                    "print('diagnostic', file=sys.stderr)",
                ],
                cwd=Path(directory),
            )
        self.assertEqual(result.stdout, "''\n")
        self.assertEqual(result.stderr, "diagnostic\n")

    def test_failed_command_preserves_diagnostics_and_check_false_result(self):
        result = subprocess.CompletedProcess(["tool"], 2, "output\n", "error\n")
        with mock.patch.object(release.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "output\\nerror"):
                release.run_command(["tool"], cwd=Path.cwd())
            unchecked = release.run_command(["tool"], cwd=Path.cwd(), check=False)
        self.assertEqual(unchecked.returncode, 2)
        self.assertEqual(unchecked.stdout, "output\n")

    def test_timeout_is_bounded_and_propagates(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            release.run_command(
                [sys.executable, "-c", "import time; time.sleep(10)"],
                cwd=Path.cwd(),
                timeout=0.1,
            )
        for timeout in (0, -1):
            with self.subTest(timeout=timeout), self.assertRaises(ValueError):
                release.run_command(["tool"], cwd=Path.cwd(), timeout=timeout)

    def test_streaming_inherits_stdout_and_stderr_and_keeps_string_contract(self):
        result = subprocess.CompletedProcess(["mise", "run", "ci"], 0)
        environment = {"TASK_OPTION": "yes"}
        with mock.patch.object(release.subprocess, "run", return_value=result) as run:
            completed = release.run_command(
                ["mise", "run", "ci"],
                cwd=Path("checkout"),
                timeout=3600,
                stream=True,
                env=environment,
            )
        run.assert_called_once_with(
            ["mise", "run", "ci"],
            cwd=Path("checkout"),
            stdin=subprocess.DEVNULL,
            capture_output=False,
            text=True,
            timeout=3600,
            check=False,
            env=environment,
        )
        self.assertEqual((completed.stdout, completed.stderr), ("", ""))


class GitRepositoryTests(unittest.TestCase):
    def setUp(self):
        self.runner = mock.Mock()
        self.git = release.GitRepository(Path("checkout"), self.runner)

    def result(self, stdout="", returncode=0, stderr=""):
        return subprocess.CompletedProcess(["git"], returncode, stdout, stderr)

    def test_changed_paths_preserves_nul_delimited_filenames(self):
        self.runner.side_effect = [
            self.result("unstaged\0a newline\nname\0"),
            self.result("staged\0unstaged\0"),
            self.result("untracked space\0"),
        ]
        self.assertEqual(
            self.git.changed_paths(),
            {"unstaged", "staged", "a newline\nname", "untracked space"},
        )
        self.assertEqual(
            self.runner.call_args_list,
            [
                mock.call(
                    ["git", "diff", "--name-only", "HEAD", "-z"],
                    cwd=Path("checkout"),
                    check=True,
                ),
                mock.call(
                    ["git", "diff", "--cached", "--name-only", "-z"],
                    cwd=Path("checkout"),
                    check=True,
                ),
                mock.call(
                    ["git", "ls-files", "--others", "--exclude-standard", "-z"],
                    cwd=Path("checkout"),
                    check=True,
                ),
            ],
        )

    def test_remote_tag_prefers_peeled_annotated_commit(self):
        self.runner.return_value = self.result(
            "tag-object\trefs/tags/v0.1.2\ncommit\trefs/tags/v0.1.2^{}\n"
        )
        self.assertEqual(self.git.remote_tag_commit("v0.1.2"), "commit")
        self.runner.assert_called_once_with(
            [
                "git",
                "ls-remote",
                "--tags",
                "origin",
                "refs/tags/v0.1.2",
                "refs/tags/v0.1.2^{}",
            ],
            cwd=Path("checkout"),
            check=True,
        )
        self.runner.return_value = self.result("commit\trefs/tags/v0.1.2\n")
        self.assertEqual(self.git.remote_tag_commit("v0.1.2"), "commit")
        self.runner.return_value = self.result()
        self.assertIsNone(self.git.remote_tag_commit("v0.1.2"))

    def test_local_tag_errors_are_not_absence(self):
        for returncode, expected in ((0, True), (1, False)):
            with self.subTest(returncode=returncode):
                self.runner.return_value = self.result(returncode=returncode)
                self.assertIs(self.git.tag_exists("v0.1.2"), expected)
        self.runner.return_value = self.result(
            returncode=128, stderr="not a repository"
        )
        with self.assertRaisesRegex(RuntimeError, "not a repository"):
            self.git.tag_exists("v0.1.2")

    def test_clean_requirement_rejects_untracked_files(self):
        self.runner.return_value = self.result("?? draft.txt\n")
        with self.assertRaisesRegex(RuntimeError, "Keep this checkout clean"):
            self.git.require_clean("Keep this checkout clean")
        self.runner.assert_called_once_with(
            ["git", "status", "--porcelain=v1", "--untracked-files=all"],
            cwd=Path("checkout"),
            check=True,
        )


class GitHubCLITests(unittest.TestCase):
    def setUp(self):
        self.runner = mock.Mock()
        self.github = release.GitHubCLI(
            REPOSITORY, cwd=Path("checkout"), runner=self.runner
        )

    def result(self, value=None, *, stdout=None, stderr="", returncode=0):
        return subprocess.CompletedProcess(
            ["gh"],
            returncode,
            json.dumps(value) if stdout is None else stdout,
            stderr,
        )

    def test_release_rest_response_is_normalized(self):
        self.runner.return_value = self.result(rest_release())
        release = self.github.get_release("v0.1.2")
        self.assertEqual(
            release,
            {
                "tagName": "v0.1.2",
                "isDraft": False,
                "isPrerelease": False,
                "assets": [{"name": "aviary.rb", "size": 100}],
                "url": rest_release()["html_url"],
            },
        )
        self.runner.assert_called_once_with(
            ["gh", "api", f"repos/{REPOSITORY}/releases/tags/v0.1.2"],
            cwd=Path("checkout"),
            check=False,
            timeout=120,
        )

    def test_paginated_release_listing_flattens_all_pages(self):
        pages = [
            [rest_release(f"v0.1.{number}") for number in range(100)],
            [rest_release("v0.2.0")],
        ]
        self.runner.return_value = self.result(pages)
        releases = self.github.list_releases()
        self.assertEqual(len(releases), 101)
        self.assertEqual(releases[-1]["tagName"], "v0.2.0")
        self.runner.assert_called_once_with(
            [
                "gh",
                "api",
                f"repos/{REPOSITORY}/releases?per_page=100",
                "--paginate",
                "--slurp",
            ],
            cwd=Path("checkout"),
            check=True,
            timeout=120,
        )

    def test_only_explicit_http_404_means_missing_release_or_formula(self):
        self.runner.return_value = self.result(
            stdout='{"message":"Not Found"}',
            stderr="gh: Not Found (HTTP 404)\n",
            returncode=1,
        )
        self.assertIsNone(self.github.get_release("v0.1.2"))
        self.assertIsNone(self.github.get_tap_formula())
        failures = (
            ("", "gh: Unauthorized (HTTP 401)"),
            ("", "gh: rate limit exceeded (HTTP 403)"),
            ("", "failed to connect to api.github.com"),
            ('{"message":"Not Found"}', "authentication required"),
            ("(HTTP 404)", "transport failure"),
        )
        for stdout, stderr in failures:
            with self.subTest(stderr=stderr):
                self.runner.return_value = self.result(
                    stdout=stdout, stderr=stderr, returncode=1
                )
                with self.assertRaisesRegex(
                    RuntimeError, stderr.replace("(", r"\(").replace(")", r"\)")
                ):
                    self.github.get_release("v0.1.2")
                with self.assertRaises(RuntimeError):
                    self.github.get_tap_formula()

    def test_invalid_successful_json_fails_closed(self):
        responses = (
            "not JSON",
            "[]",
            '{"tag_name":"v0.1.2"}',
            json.dumps({**rest_release(), "draft": "false"}),
            json.dumps({**rest_release(), "assets": [{"size": 1}]}),
        )
        for output in responses:
            with self.subTest(output=output):
                self.runner.return_value = self.result(stdout=output)
                with self.assertRaises(RuntimeError):
                    self.github.get_release("v0.1.2")
        for response in ({}, [rest_release()], [None]):
            with self.subTest(response=response):
                self.runner.return_value = self.result(response)
                with self.assertRaises(RuntimeError):
                    self.github.list_releases()

    def test_workflow_adapter_uses_candidate_filters(self):
        run = {
            "databaseId": 17,
            "headSha": "candidate",
            "headBranch": "main",
            "event": "push",
        }
        self.runner.return_value = self.result([run])
        self.assertEqual(self.github.list_runs("ci.yml", "main", "candidate"), [run])
        self.runner.assert_called_once_with(
            [
                "gh",
                "run",
                "list",
                "--repo",
                REPOSITORY,
                "--workflow",
                "ci.yml",
                "--event",
                "push",
                "--branch",
                "main",
                "--commit",
                "candidate",
                "--limit",
                "100",
                "--json",
                "databaseId,headSha,headBranch,event",
            ],
            cwd=Path("checkout"),
            check=True,
            timeout=120,
        )
        run |= {
            "status": "queued",
            "conclusion": None,
            "url": "https://example.invalid/run/17",
            "jobs": [],
        }
        self.runner.return_value = self.result(run)
        self.assertEqual(self.github.get_run(17), run)

    def test_workflow_and_secret_shape_validation(self):
        for response in ({}, [None], [{"databaseId": True}], [{"databaseId": 1}]):
            with self.subTest(response=response):
                self.runner.return_value = self.result(response)
                with self.assertRaises(RuntimeError):
                    self.github.list_runs("ci.yml", "main", "candidate")
        self.runner.return_value = self.result([{"name": "HOMEBREW_TAP_TOKEN"}])
        self.assertEqual(self.github.secret_names(), {"HOMEBREW_TAP_TOKEN"})
        self.runner.return_value = self.result([{"name": None}])
        with self.assertRaises(RuntimeError):
            self.github.secret_names()

    def test_asset_commands_keep_verified_drafts_and_explicit_latest(self):
        self.runner.return_value = self.result(stdout="")
        assets = [Path("dist/archive.tar.gz"), Path("dist/aviary.rb")]
        self.github.create_draft("v0.1.2", assets)
        self.github.upload_assets("v0.1.2", assets)
        self.github.publish_release("v0.1.2", latest=False)
        self.github.publish_release("v0.1.3", latest=True)
        self.assertEqual(
            self.runner.call_args_list,
            [
                mock.call(
                    [
                        "gh",
                        "release",
                        "create",
                        "v0.1.2",
                        "--repo",
                        REPOSITORY,
                        "--verify-tag",
                        "--draft",
                        "--title",
                        "Aviary 0.1.2",
                        "--generate-notes",
                        "dist/archive.tar.gz",
                        "dist/aviary.rb",
                    ],
                    cwd=Path("checkout"),
                    check=True,
                    timeout=300,
                ),
                mock.call(
                    [
                        "gh",
                        "release",
                        "upload",
                        "v0.1.2",
                        "--repo",
                        REPOSITORY,
                        "dist/archive.tar.gz",
                        "dist/aviary.rb",
                        "--clobber",
                    ],
                    cwd=Path("checkout"),
                    check=True,
                    timeout=300,
                ),
                mock.call(
                    [
                        "gh",
                        "release",
                        "edit",
                        "v0.1.2",
                        "--repo",
                        REPOSITORY,
                        "--draft=false",
                        "--latest=false",
                    ],
                    cwd=Path("checkout"),
                    check=True,
                    timeout=120,
                ),
                mock.call(
                    [
                        "gh",
                        "release",
                        "edit",
                        "v0.1.3",
                        "--repo",
                        REPOSITORY,
                        "--draft=false",
                        "--latest=true",
                    ],
                    cwd=Path("checkout"),
                    check=True,
                    timeout=120,
                ),
            ],
        )

    def test_download_requires_an_actual_formula(self):
        self.runner.return_value = self.result(stdout="")
        with tempfile.TemporaryDirectory(
            prefix="aviary-formula-download-"
        ) as directory:
            destination = Path(directory)
            with self.assertRaisesRegex(RuntimeError, "did not download"):
                self.github.download_formula("v0.1.2", destination)
            formula = destination / "aviary.rb"
            formula.write_text("class Aviary < Formula\nend\n")
            self.assertEqual(
                self.github.download_formula("v0.1.2", destination), formula
            )
            self.runner.assert_called_with(
                [
                    "gh",
                    "release",
                    "download",
                    "v0.1.2",
                    "--repo",
                    REPOSITORY,
                    "--pattern",
                    "aviary.rb",
                    "--dir",
                    str(destination),
                ],
                cwd=Path("checkout"),
                check=True,
                timeout=300,
            )

    def test_auth_tap_fetch_and_clone_use_configured_repositories(self):
        self.runner.return_value = self.result(stdout="class Aviary < Formula\nend\n")
        github = release.GitHubCLI(
            REPOSITORY,
            cwd=Path("checkout"),
            runner=self.runner,
            tap_repository="example/homebrew-tap",
        )
        github.check_auth()
        self.assertEqual(github.get_tap_formula(), "class Aviary < Formula\nend\n")
        github.clone_tap(Path("tap"))
        self.assertEqual(
            self.runner.call_args_list,
            [
                mock.call(
                    ["gh", "auth", "status"],
                    cwd=Path("checkout"),
                    check=True,
                    timeout=120,
                ),
                mock.call(
                    [
                        "gh",
                        "api",
                        "repos/example/homebrew-tap/contents/Formula/aviary.rb",
                        "--header",
                        "Accept: application/vnd.github.raw",
                    ],
                    cwd=Path("checkout"),
                    check=False,
                    timeout=120,
                ),
                mock.call(
                    ["gh", "repo", "clone", "example/homebrew-tap", "tap"],
                    cwd=Path("checkout"),
                    check=True,
                    timeout=300,
                ),
            ],
        )


class WorkflowGitHubFixture:
    """Semantic GitHub responses for the local release workflow."""

    repository = REPOSITORY
    tap_repository = "grahamannett/homebrew-tap"

    def __init__(self, fixture):
        self.fixture = fixture

    def record(self, *args):
        command = ["gh", *args]
        self.fixture.commands.append(command)
        if self.fixture.interrupt is not None and self.fixture.interrupt(command):
            self.fixture.interrupt = None
            raise KeyboardInterrupt("Simulated interruption")

    def check_auth(self):
        self.record("auth", "status")

    def secret_names(self):
        self.record("secret", "list")
        return {"HOMEBREW_TAP_TOKEN"} if self.fixture.secret_present else set()

    def list_runs(self, workflow, branch, commit):
        self.record("run", "list", workflow)
        head = self.fixture.git("rev-parse", "HEAD").strip()
        self.fixture.assertEqual(commit, head)
        runs = [
            dict(databaseId=90, headSha="0" * 40, headBranch=branch, event="push"),
            dict(databaseId=91, headSha=head, headBranch="unrelated", event="push"),
            dict(databaseId=92, headSha=head, headBranch=branch, event="pull_request"),
        ]
        if not self.fixture.unrelated_only:
            runs.append(
                dict(
                    databaseId=10 if workflow == "ci.yml" else 20,
                    headSha=head,
                    headBranch=branch,
                    event="push",
                )
            )
        return runs

    def get_run(self, run_id):
        self.record("run", "view", str(run_id))
        self.fixture.assertIn(run_id, (10, 20))
        is_release = run_id == 20
        fixture = self.fixture
        jobs = []
        if is_release:
            jobs.append(
                dict(
                    name="publish",
                    conclusion=fixture.release_conclusion
                    if fixture.tap_step_conclusion == "success"
                    else "success",
                )
            )
            if not fixture.omit_tap_step:
                jobs.append(
                    dict(
                        name="homebrew",
                        databaseId=fixture.tap_job_id,
                        conclusion=fixture.tap_step_conclusion,
                    )
                )
        result = dict(
            databaseId=run_id,
            headSha=fixture.git("rev-parse", "HEAD").strip(),
            headBranch=TAG if is_release else "main",
            event="push",
            status="completed",
            conclusion=fixture.release_conclusion
            if is_release
            else fixture.ci_conclusion,
            url=f"https://example.invalid/run/{run_id}",
            jobs=jobs,
        )
        result.update(fixture.run_metadata)
        return result

    def get_release(self, tag):
        self.record("release", "view", tag)
        self.fixture.assertEqual(tag, TAG)
        return dict(
            tagName=tag,
            isDraft=False,
            isPrerelease=False,
            url="https://example.invalid/release",
            assets=[
                dict(name=name)
                for name in release.expected_assets(VERSION)
                if name != self.fixture.missing_asset
            ],
        )

    def download_formula(self, tag, destination):
        self.record("release", "download", tag)
        self.fixture.assertEqual(tag, TAG)
        path = destination / "aviary.rb"
        path.write_text(self.fixture.formula)
        return path

    def get_tap_formula(self):
        self.record("api", "tap-formula")
        return (
            self.fixture.formula
            if self.fixture.tap_matches
            else 'class Aviary < Formula\n  version "0.1.1"\nend\n'
        )


class PublishTests(unittest.TestCase):
    def setUp(self):
        # Retain fixtures for inspection; no real checkout or remote is modified.
        self.root = Path(tempfile.mkdtemp(prefix="aviary-publish-tests-"))
        self.repository = self.root / "checkout"
        self.repository.mkdir()
        self.remote = self.root / "origin.git"
        self.git_env = dict(
            os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull
        )
        self.git_env.pop("GIT_DIR", None)
        self.git_env.pop("GIT_WORK_TREE", None)
        self.git("init", "--bare", "--initial-branch=main", str(self.remote))
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "release@example.invalid")
        self.git(
            "config",
            "url." + str(self.remote) + ".insteadOf",
            "git@github.com:" + REPOSITORY + ".git",
        )
        self.git("remote", "add", "origin", "git@github.com:" + REPOSITORY + ".git")
        self.write(
            "Sources/AviaryCLI/AviaryRoot.swift",
            'struct AviaryRoot {\n    static let configuration = CommandConfiguration(\n        version: "0.1.1",\n    )\n}\n',
        )
        self.write(
            "mise.test.toml",
            "[env]\n    version = \"{{ env.AVIARY_INSTALL_TEST_VERSION | default(value='0.1.1') }}\"\n",
        )
        self.write(
            "README.md",
            "Install:\n\nmise use -g github:grahamannett/aviary-swift@0.1.1\n",
        )
        self.write(
            "docs/distribution.md",
            'mise use -g github:grahamannett/aviary-swift@0.1.1\n"github:grahamannett/aviary-swift" = "0.1.1"\narchive aviary-0.1.1-macos-arm64.tar.gz\n',
        )
        self.write("notes.txt", "Unrelated content must survive publication.\n")
        self.git("add", ".")
        self.git("commit", "-m", "Initial fixture")
        self.git("tag", "-a", "v0.1.1", "-m", "Previous fixture release")
        self.git("push", "-u", "origin", "main")
        self.git("push", "origin", "refs/tags/v0.1.1")
        self.initial_head = self.git("rev-parse", "HEAD").strip()
        self.initial_contents = {
            path: (self.repository / path).read_text() for path in VERSION_FILES
        }
        self.commands = []
        self.local_checks_fail = False
        self.ci_conclusion = "success"
        self.release_conclusion = "success"
        self.tap_step_conclusion = "success"
        self.tap_job_id = 200
        self.omit_tap_step = False
        self.tap_matches = True
        self.secret_present = True
        self.missing_tool = None
        self.requested_tag = TAG
        self.missing_asset = None
        self.unrelated_only = False
        self.run_metadata = {}
        self.interrupt = None
        self.clock = 0
        self.formula = 'class Aviary < Formula\n  version "0.1.2"\nend\n'

    def write(self, relative, content):
        path = self.repository / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def git(self, *args, cwd=None):
        return subprocess.check_output(
            ["/usr/bin/git", *args],
            cwd=cwd or self.repository,
            env=self.git_env,
            text=True,
            stderr=subprocess.STDOUT,
        )

    def completed(self, args, output="", returncode=0, check=True):
        result = subprocess.CompletedProcess(args, returncode, output, "")
        if check and returncode:
            raise subprocess.CalledProcessError(returncode, args, output=output)
        return result

    def command(self, args, *, cwd, timeout=120, check=True, stream=False):
        args = list(map(str, args))
        self.assertEqual(Path(cwd).resolve(), self.repository.resolve())
        self.commands.append(args)
        if self.interrupt is not None and self.interrupt(args):
            self.interrupt = None
            raise KeyboardInterrupt("Simulated interruption")
        if args[0] == "git":
            self.assertIn(
                args[1],
                {
                    "rev-parse",
                    "status",
                    "branch",
                    "symbolic-ref",
                    "remote",
                    "config",
                    "fetch",
                    "show-ref",
                    "ls-remote",
                    "ls-files",
                    "ls-tree",
                    "merge-base",
                    "cat-file",
                    "log",
                    "diff",
                    "show",
                    "add",
                    "commit",
                    "push",
                    "tag",
                },
            )
            if args[1] == "config":
                self.assertEqual(args, ["git", "config", "--get", "remote.origin.url"])
            if args[1] == "remote":
                self.assertIn(
                    args,
                    [
                        ["git", "remote", "get-url", "--all", "origin"],
                        ["git", "remote", "get-url", "--push", "--all", "origin"],
                    ],
                )
            if args[1] == "fetch":
                self.assertEqual(args, ["git", "fetch", "origin", "main", "--tags"])
            if args[1] == "push":
                self.assertIn(
                    args,
                    [
                        ["git", "push", "origin", "main"],
                        ["git", "push", "origin", f"refs/tags/{TAG}"],
                    ],
                )
            if args[1] == "ls-remote":
                self.assertEqual(
                    args,
                    [
                        "git",
                        "ls-remote",
                        "--tags",
                        "origin",
                        f"refs/tags/{self.requested_tag}",
                        f"refs/tags/{self.requested_tag}^{{}}",
                    ],
                )
            if args[1] == "add":
                self.assertEqual(args, ["git", "add", "--", *VERSION_FILES])
            if args[1] == "commit":
                self.assertEqual(
                    args, ["git", "commit", "-m", f"Release Aviary {VERSION}"]
                )
            if args[1] == "tag":
                self.assertIn(
                    args,
                    [
                        ["git", "tag", "--list"],
                        [
                            "git",
                            "tag",
                            "-a",
                            TAG,
                            self.git("rev-parse", "HEAD").strip(),
                            "-m",
                            f"Aviary {VERSION}",
                        ],
                    ],
                )
            if args[1] in {"fetch", "push", "ls-remote"}:
                options = ("--push", "--all") if args[1] == "push" else ("--all",)
                effective = self.git(
                    "remote", "get-url", *options, "origin"
                ).splitlines()
                self.assertEqual(
                    effective,
                    [str(self.remote)],
                    "Fixture network operations must resolve only to the local bare remote",
                )
            result = subprocess.run(
                ["/usr/bin/git", *args[1:]],
                cwd=self.repository,
                env=self.git_env,
                text=True,
                capture_output=True,
                timeout=timeout,
            )
            if args[1] == "remote":
                # Expose the canonical URL only for this exact local fixture mapping.
                result.stdout = (
                    "\n".join(
                        "git@github.com:" + REPOSITORY + ".git"
                        if line == str(self.remote)
                        else line
                        for line in result.stdout.splitlines()
                    )
                    + "\n"
                )
            return self.completed(
                args, result.stdout + result.stderr, result.returncode, check
            )
        if args[0] == "mise":
            self.assertIn(args, [["mise", "run", "ci"], ["mise", "run", "build"]])
            return self.completed(
                args,
                "Local checks failed"
                if self.local_checks_fail
                else "Local checks passed",
                int(self.local_checks_fail),
                check,
            )
        self.fail(f"Unmocked external command: {args}")

    def advance_clock(self, seconds):
        self.clock += seconds

    def publish(self, version=VERSION, *, resume=False):
        self.requested_tag = "v" + version.removeprefix("v")
        self.output = io.StringIO()
        with (
            contextlib.redirect_stdout(self.output),
            mock.patch.object(release, "run_command", self.command),
            mock.patch.object(
                release,
                "GitHubCLI",
                lambda *args, **kwargs: WorkflowGitHubFixture(self),
            ),
            mock.patch.object(
                release.shutil,
                "which",
                lambda tool: (
                    None if tool == self.missing_tool else "/offline/tools/" + tool
                ),
            ),
            mock.patch.object(release, "PUBLISH_DISCOVERY_TIMEOUT", 3),
            mock.patch.object(release, "PUBLISH_WORKFLOW_TIMEOUT", 3),
            mock.patch.object(release, "PUBLISH_POLL_INTERVAL", 1),
            mock.patch.object(release.time, "sleep", self.advance_clock),
            mock.patch.object(release.time, "monotonic", lambda: self.clock),
        ):
            return release.publish(
                version, resume=resume, repository_dir=self.repository
            )

    def is_git_mutation(self, command):
        return command[0] == "git" and (
            command[1] in {"add", "commit", "push"}
            or (
                command[1] == "tag"
                and not any(option in command for option in ("-l", "--list"))
            )
        )

    def assert_no_publication(self):
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), self.initial_head)
        self.assertEqual(
            self.git("ls-remote", "origin", "refs/heads/main").split()[0],
            self.initial_head,
        )
        self.assertEqual(self.git("tag", "--list", TAG).strip(), "")
        self.assertEqual(
            self.git("ls-remote", "--tags", "origin", "refs/tags/" + TAG).strip(), ""
        )
        self.assertFalse(
            any(self.is_git_mutation(command) for command in self.commands)
        )

    def test_invalid_or_nonincreasing_versions_are_rejected_before_edits(self):
        for version in ("invalid", "0.1.2-beta", "0.1.1", "0.1.0"):
            with (
                self.subTest(version=version),
                self.assertRaises((ValueError, RuntimeError)),
            ):
                self.publish(version)
            self.assert_no_publication()
            self.assertEqual(
                {path: (self.repository / path).read_text() for path in VERSION_FILES},
                self.initial_contents,
            )

    def test_publish_commits_only_version_files_and_verifies_release_and_tap(self):
        self.publish()
        head = self.git("rev-parse", "HEAD").strip()
        self.assertNotEqual(head, self.initial_head)
        self.assertEqual(self.git("rev-parse", "HEAD^").strip(), self.initial_head)
        self.assertEqual(
            set(
                self.git(
                    "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"
                ).splitlines()
            ),
            set(VERSION_FILES),
        )
        self.assertEqual(self.git("status", "--porcelain").strip(), "")
        self.assertEqual(self.git("rev-parse", TAG + "^{commit}").strip(), head)
        self.assertEqual(
            self.git("ls-remote", "origin", "refs/heads/main").split()[0], head
        )
        self.assertTrue(
            self.git("ls-remote", "--tags", "origin", "refs/tags/" + TAG).strip()
        )
        self.assertEqual(
            (self.repository / "notes.txt").read_text(),
            "Unrelated content must survive publication.\n",
        )
        self.assertTrue(
            any(command[:3] == ["gh", "release", "view"] for command in self.commands)
        )
        self.assertTrue(any(command[:2] == ["gh", "api"] for command in self.commands))

    def test_dirty_worktree_is_rejected_without_publication(self):
        self.write("notes.txt", "User edits\n")
        with self.assertRaises(RuntimeError):
            self.publish()
        self.assert_no_publication()
        self.assertEqual((self.repository / "notes.txt").read_text(), "User edits\n")
        self.assertEqual(
            {path: (self.repository / path).read_text() for path in VERSION_FILES},
            self.initial_contents,
        )

    def test_wrong_branch_is_rejected_without_publication(self):
        self.git("switch", "-c", "feature")
        with self.assertRaises(RuntimeError):
            self.publish()
        self.assert_no_publication()

    def test_wrong_effective_pushurl_is_rejected_before_side_effects(self):
        self.git(
            "config",
            "remote.origin.pushurl",
            "https://github.com/unrelated/project.git",
        )
        with self.assertRaises(RuntimeError):
            self.publish()
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), self.initial_head)
        self.assertEqual(
            {path: (self.repository / path).read_text() for path in VERSION_FILES},
            self.initial_contents,
        )
        self.assertFalse(
            any(self.is_git_mutation(command) for command in self.commands)
        )
        self.assertFalse(any(command[0] in {"gh", "mise"} for command in self.commands))

    def test_wrong_effective_url_rewrite_is_rejected_before_side_effects(self):
        self.git("config", "--unset-all", "url." + str(self.remote) + ".insteadOf")
        self.git(
            "config",
            "url.https://github.com/unrelated/project.git.insteadOf",
            "git@github.com:" + REPOSITORY + ".git",
        )
        with self.assertRaises(RuntimeError):
            self.publish()
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), self.initial_head)
        self.assertEqual(
            {path: (self.repository / path).read_text() for path in VERSION_FILES},
            self.initial_contents,
        )
        self.assertFalse(
            any(self.is_git_mutation(command) for command in self.commands)
        )
        self.assertFalse(any(command[0] in {"gh", "mise"} for command in self.commands))

    def test_local_main_diverged_from_origin_is_rejected(self):
        other = self.root / "other-checkout"
        self.git("clone", str(self.remote), str(other))
        self.git("config", "user.name", "Other test", cwd=other)
        self.git("config", "user.email", "other@example.invalid", cwd=other)
        (other / "notes.txt").write_text("A new remote commit\n")
        self.git("add", "notes.txt", cwd=other)
        self.git("commit", "-m", "Remote fixture work", cwd=other)
        self.git("push", "origin", "main", cwd=other)
        remote_head = self.git("rev-parse", "HEAD", cwd=other).strip()
        self.write("notes.txt", "An unpushed commit\n")
        self.git("add", "notes.txt")
        self.git("commit", "-m", "Unpushed fixture work")
        head = self.git("rev-parse", "HEAD").strip()
        with self.assertRaises(RuntimeError):
            self.publish()
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), head)
        self.assertEqual(
            self.git("ls-remote", "origin", "refs/heads/main").split()[0], remote_head
        )
        self.assertFalse(
            any(
                command[0] == "git" and command[1] in {"commit", "push", "tag"}
                for command in self.commands
            )
        )

    def test_existing_tag_is_rejected_without_editing_version(self):
        self.git("tag", TAG)
        with self.assertRaises(RuntimeError):
            self.publish()
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), self.initial_head)
        self.assertEqual(self.git("rev-parse", TAG).strip(), self.initial_head)
        self.assertEqual(
            {path: (self.repository / path).read_text() for path in VERSION_FILES},
            self.initial_contents,
        )
        self.assertFalse(
            any(
                command[0] == "git" and command[1] in {"commit", "push"}
                for command in self.commands
            )
        )

    def test_existing_remote_tag_is_rejected_without_editing_version(self):
        self.git("tag", "-a", TAG, "-m", "Existing remote release")
        self.git("push", "origin", f"refs/tags/{TAG}")
        tag_object = self.git("rev-parse", TAG).strip()
        self.git("tag", "-d", TAG)
        with self.assertRaises(RuntimeError):
            self.publish()
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), self.initial_head)
        self.assertEqual(self.git("rev-parse", TAG).strip(), tag_object)
        self.assertEqual(
            {path: (self.repository / path).read_text() for path in VERSION_FILES},
            self.initial_contents,
        )
        self.assertFalse(
            any(self.is_git_mutation(command) for command in self.commands)
        )

    def test_resume_rejects_mismatched_tag_without_moving_it(self):
        self.git("tag", "-a", TAG, "-m", "Tag contains the wrong version")
        tag_object = self.git("rev-parse", TAG).strip()
        with self.assertRaises(RuntimeError):
            self.publish(resume=True)
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), self.initial_head)
        self.assertEqual(self.git("rev-parse", TAG).strip(), tag_object)
        self.assertEqual(
            {path: (self.repository / path).read_text() for path in VERSION_FILES},
            self.initial_contents,
        )
        self.assertFalse(
            any(self.is_git_mutation(command) for command in self.commands)
        )

    def test_missing_tap_secret_is_rejected_before_version_edits(self):
        self.secret_present = False
        with self.assertRaises(RuntimeError):
            self.publish()
        self.assert_no_publication()
        self.assertEqual(
            {path: (self.repository / path).read_text() for path in VERSION_FILES},
            self.initial_contents,
        )

    def test_missing_tool_is_rejected_before_any_commands(self):
        self.missing_tool = "mise"
        with self.assertRaises(RuntimeError):
            self.publish()
        self.assertEqual(self.commands, [])
        self.assert_no_publication()

    def test_failed_local_checks_keep_version_edits_without_committing(self):
        self.local_checks_fail = True
        with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
            self.publish()
        self.assert_no_publication()
        self.assertIn('"0.1.2"', (self.repository / VERSION_FILES[0]).read_text())
        self.assertEqual(
            (self.repository / "notes.txt").read_text(),
            "Unrelated content must survive publication.\n",
        )

    def test_resume_after_failed_local_checks_accepts_only_owned_version_edits(self):
        self.local_checks_fail = True
        with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
            self.publish()
        self.local_checks_fail = False
        self.publish(resume=True)
        self.assertEqual(self.git("rev-parse", "HEAD^").strip(), self.initial_head)
        self.assertEqual(
            self.git("rev-parse", TAG + "^{commit}").strip(),
            self.git("rev-parse", "HEAD").strip(),
        )

    def test_resume_rejects_unrelated_edits_without_overwriting_them(self):
        self.write("notes.txt", "Unrelated user edits\n")
        with self.assertRaises(RuntimeError):
            self.publish(resume=True)
        self.assert_no_publication()
        self.assertEqual(
            (self.repository / "notes.txt").read_text(), "Unrelated user edits\n"
        )
        self.assertEqual(
            {path: (self.repository / path).read_text() for path in VERSION_FILES},
            self.initial_contents,
        )

    def test_resume_preserves_unrelated_staged_edit_hidden_by_restored_worktree(self):
        path = VERSION_FILES[0]
        staged = self.initial_contents[path] + "// Unrelated staged user edit\n"
        self.write(path, staged)
        self.git("add", "--", path)
        self.write(path, self.initial_contents[path])
        index = self.git("ls-files", "--stage", "--", path)
        with self.assertRaises(RuntimeError):
            self.publish(resume=True)
        self.assert_no_publication()
        self.assertEqual(self.git("show", ":" + path), staged)
        self.assertEqual(self.git("ls-files", "--stage", "--", path), index)
        self.assertEqual(
            {path: (self.repository / path).read_text() for path in VERSION_FILES},
            self.initial_contents,
        )

    def test_failed_ci_does_not_create_or_push_a_tag(self):
        for conclusion in ("failure", "cancelled"):
            self.ci_conclusion = conclusion
            with (
                self.subTest(conclusion=conclusion),
                self.assertRaises(RuntimeError) as raised,
            ):
                self.publish()
            self.assertIn(
                f"gh run rerun 10 --failed --repo {REPOSITORY}", str(raised.exception)
            )
        head = self.git("rev-parse", "HEAD").strip()
        self.assertNotEqual(head, self.initial_head)
        self.assertEqual(
            self.git("ls-remote", "origin", "refs/heads/main").split()[0], head
        )
        self.assertEqual(self.git("tag", "--list", TAG).strip(), "")
        self.assertFalse(
            any(command[:3] == ["gh", "release", "view"] for command in self.commands)
        )

    def test_unrelated_successful_runs_do_not_allow_tagging(self):
        self.unrelated_only = True
        with self.assertRaises(RuntimeError):
            self.publish()
        self.assertEqual(self.git("tag", "--list", TAG).strip(), "")
        self.assertFalse(
            any(command[:3] == ["gh", "run", "view"] for command in self.commands)
        )

    def test_changed_run_metadata_is_rejected(self):
        for metadata in (
            {"headSha": "0" * 40},
            {"headBranch": "unrelated"},
            {"event": "pull_request"},
        ):
            self.run_metadata = metadata
            with self.subTest(metadata=metadata), self.assertRaises(RuntimeError):
                self.publish()
            self.assertEqual(self.git("tag", "--list", TAG).strip(), "")

    def test_failed_release_workflow_is_not_reported_as_success(self):
        self.release_conclusion = "failure"
        with self.assertRaises(RuntimeError) as raised:
            self.publish()
        self.assertIn(
            f"gh run rerun 20 --failed --repo {REPOSITORY}", str(raised.exception)
        )
        self.assertTrue(
            self.git("ls-remote", "--tags", "origin", f"refs/tags/{TAG}").strip()
        )
        self.assertNotIn("Released", self.output.getvalue())

    def test_resume_after_main_push_does_not_duplicate_release_commit(self):
        self.interrupt = lambda command: command[:3] == ["gh", "run", "list"]
        with self.assertRaises(KeyboardInterrupt):
            self.publish()
        self.assertIn(f"mise run release -- {VERSION} --resume", self.output.getvalue())
        release_head = self.git("rev-parse", "HEAD").strip()
        self.publish(resume=True)
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), release_head)
        self.assertEqual(self.git("rev-parse", "HEAD^").strip(), self.initial_head)
        self.assertEqual(self.git("rev-parse", TAG + "^{commit}").strip(), release_head)
        self.assertEqual(
            sum(command[:2] == ["git", "commit"] for command in self.commands), 1
        )

    def test_resume_after_tag_push_keeps_existing_tag(self):
        self.interrupt = lambda command: (
            command[:3] == ["gh", "run", "list"] and "release.yml" in command
        )
        with self.assertRaises(KeyboardInterrupt):
            self.publish()
        tag_object = self.git("rev-parse", TAG).strip()
        self.publish(resume=True)
        self.assertEqual(self.git("rev-parse", TAG).strip(), tag_object)
        self.assertEqual(
            sum(command[:2] == ["git", "commit"] for command in self.commands), 1
        )
        self.assertEqual(
            sum(
                command[:2] == ["git", "tag"]
                for command in self.commands
                if command[2:3] != ["--list"]
            ),
            1,
        )

    def test_resuming_completed_release_has_no_new_commits_or_pushes(self):
        self.publish()
        head = self.git("rev-parse", "HEAD").strip()
        tag_object = self.git("rev-parse", TAG).strip()
        self.commands.clear()
        self.publish(resume=True)
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), head)
        self.assertEqual(self.git("rev-parse", TAG).strip(), tag_object)
        self.assertFalse(
            any(self.is_git_mutation(command) for command in self.commands)
        )

    def test_remote_tag_resume_requires_successful_main_ci_for_exact_sha(self):
        self.publish()
        head = self.git("rev-parse", "HEAD").strip()
        tag_object = self.git("rev-parse", TAG).strip()
        self.commands.clear()
        self.ci_conclusion = "failure"
        with self.assertRaises(RuntimeError):
            self.publish(resume=True)
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), head)
        self.assertEqual(self.git("rev-parse", TAG).strip(), tag_object)
        self.assertTrue(
            any(command[:4] == ["gh", "run", "view", "10"] for command in self.commands)
        )
        self.assertFalse(
            any(command[:4] == ["gh", "run", "view", "20"] for command in self.commands)
        )
        self.assertFalse(
            any(command[:3] == ["gh", "release", "view"] for command in self.commands)
        )
        self.assertFalse(
            any(self.is_git_mutation(command) for command in self.commands)
        )

    def test_incomplete_assets_are_not_reported_as_success(self):
        self.missing_asset = f"aviary-{VERSION}-linux-arm64.tar.gz"
        with self.assertRaises(RuntimeError):
            self.publish()

    def test_skipped_or_missing_tap_update_is_not_reported_as_success(self):
        self.tap_step_conclusion = "skipped"
        self.tap_matches = False
        for omitted in (False, True):
            self.omit_tap_step = omitted
            with (
                self.subTest(omitted=omitted),
                self.assertRaises(RuntimeError) as raised,
            ):
                self.publish(resume=omitted)
            self.assertIn(
                f"gh run rerun 20 --job 200 --repo {REPOSITORY}"
                if not omitted
                else f"mise run repair-tap -- {VERSION}",
                str(raised.exception),
            )

    def test_tap_rerun_guidance_falls_back_when_job_id_is_unavailable(self):
        self.tap_step_conclusion = "skipped"
        self.tap_matches = False
        self.tap_job_id = None
        with self.assertRaises(RuntimeError) as raised:
            self.publish()
        self.assertIn(f"mise run repair-tap -- {VERSION}", str(raised.exception))
        self.assertNotIn("--job", str(raised.exception))

    def test_tap_formula_mismatch_is_not_reported_as_success(self):
        self.tap_matches = False
        with self.assertRaises(RuntimeError):
            self.publish()


class PublishGuidanceTests(unittest.TestCase):
    def test_interrupted_cli_exits_130_without_traceback(self):
        output = io.StringIO()
        with (
            contextlib.redirect_stderr(output),
            mock.patch.object(release, "publish", side_effect=KeyboardInterrupt),
        ):
            with self.assertRaises(SystemExit) as raised:
                release.main(["publish", VERSION])
        self.assertEqual(raised.exception.code, 130)
        self.assertNotIn("Traceback", output.getvalue())


class WorkflowPollingTests(unittest.TestCase):
    def setUp(self):
        self.clock = 0
        self.github = mock.Mock(repository=REPOSITORY)
        self.run = dict(
            databaseId=20,
            headSha="candidate",
            headBranch=TAG,
            event="push",
            status="completed",
            conclusion="success",
            url="https://example.invalid/run/20",
            jobs=[],
        )
        self.github.list_runs.return_value = [self.run]
        self.github.get_run.return_value = self.run
        patches = (
            mock.patch.object(release.time, "monotonic", lambda: self.clock),
            mock.patch.object(release.time, "sleep", self.advance_clock),
            mock.patch.object(release, "PUBLISH_DISCOVERY_TIMEOUT", 3),
            mock.patch.object(release, "PUBLISH_WORKFLOW_TIMEOUT", 3),
            mock.patch.object(release, "PUBLISH_POLL_INTERVAL", 1),
        )
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def advance_clock(self, seconds):
        self.clock += seconds

    def wait(self, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            return release.wait_for_workflow(
                self.github, "release.yml", TAG, "candidate", **kwargs
            )

    def test_delayed_discovery_and_status_transitions(self):
        self.github.list_runs.side_effect = [[], [], [self.run]]
        self.github.get_run.side_effect = [
            dict(self.run, status="queued", conclusion=None),
            dict(self.run, status="in_progress", conclusion=None),
            self.run,
        ]
        self.assertEqual(self.wait(), self.run)
        self.assertEqual(self.clock, 4)
        self.assertEqual(self.github.get_run.call_count, 3)

    def test_newest_matching_run_is_selected(self):
        self.github.list_runs.return_value = [
            dict(self.run, databaseId=10),
            self.run,
            dict(self.run, databaseId=90, headSha="unrelated"),
        ]
        self.wait()
        self.github.get_run.assert_called_once_with(20)

    def test_discovery_timeout_never_observes_unrelated_runs(self):
        self.github.list_runs.return_value = [dict(self.run, headBranch="unrelated")]
        with self.assertRaisesRegex(RuntimeError, "No release.yml push run appeared"):
            self.wait()
        self.github.get_run.assert_not_called()
        self.assertEqual(self.clock, 3)

    def test_running_workflow_has_bounded_wait(self):
        self.github.get_run.return_value = dict(
            self.run, status="in_progress", conclusion=None
        )
        with self.assertRaisesRegex(RuntimeError, "Timed out waiting"):
            self.wait()
        self.assertEqual(self.clock, 3)

    def test_changed_run_id_is_rejected(self):
        self.github.get_run.return_value = dict(self.run, databaseId=21)
        with self.assertRaisesRegex(RuntimeError, "does not match"):
            self.wait()

    def test_failed_release_is_returned_for_partial_success_inspection(self):
        self.github.get_run.return_value = dict(self.run, conclusion="failure")
        self.assertEqual(self.wait(require_success=False)["conclusion"], "failure")
        with self.assertRaisesRegex(RuntimeError, "gh run rerun 20 --failed"):
            self.wait()


def formula_contents(version):
    return f'class Aviary < Formula\n  version "{version}"\nend\n'


def release_record(version, *, draft=False, prerelease=False):
    return {
        "tagName": f"v{version}",
        "isDraft": draft,
        "isPrerelease": prerelease,
        "assets": [{"name": name} for name in sorted(release.expected_assets(version))],
        "url": f"https://github.com/{release.PUBLISH_REPOSITORY}/releases/tag/v{version}",
    }


def write_asset_fixtures(directory, version):
    for name in release.expected_assets(version) - {"SHA256SUMS", "aviary.rb"}:
        content = f"verified fixture {name}".encode()
        (directory / name).write_bytes(content)
        (directory / f"{name}.sha256").write_text(
            f"{hashlib.sha256(content).hexdigest()}  {name}\n"
        )


class ReleaseStore:
    """In-memory release states; record transport actions without matching argv."""

    repository = release.PUBLISH_REPOSITORY
    tap_repository = TAP_REPOSITORY

    def __init__(self):
        self.releases = {}
        self.formulas = {}
        self.calls = []
        self.tap = None

    def add_release(self, version, *, draft=False, prerelease=False, content=None):
        self.releases[f"v{version}"] = release_record(
            version, draft=draft, prerelease=prerelease
        )
        self.formulas[f"v{version}"] = content or formula_contents(version)

    def get_release(self, tag):
        self.calls.append(("get_release", tag))
        return copy.deepcopy(self.releases.get(tag))

    def list_releases(self):
        self.calls.append(("list_releases",))
        return copy.deepcopy(list(self.releases.values()))

    def create_draft(self, tag, assets):
        self.calls.append(("create_draft", tag))
        self.releases[tag] = release_record(tag.removeprefix("v"), draft=True)
        self.formulas[tag] = next(
            asset for asset in assets if asset.name == "aviary.rb"
        ).read_text()

    def upload_assets(self, tag, assets):
        self.calls.append(("upload_assets", tag))
        self.releases[tag]["assets"] = [{"name": asset.name} for asset in assets]
        self.formulas[tag] = next(
            asset for asset in assets if asset.name == "aviary.rb"
        ).read_text()

    def publish_release(self, tag, *, latest):
        self.calls.append(("publish_release", tag, latest))
        self.releases[tag]["isDraft"] = False

    def download_formula(self, tag, destination):
        self.calls.append(("download_formula", tag))
        path = destination / "aviary.rb"
        path.write_text(self.formulas[tag])
        return path

    def get_tap_formula(self):
        self.calls.append(("get_tap_formula",))
        return self.tap


class AssetPublicationTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="aviary-assets-policy-"))
        self.github = ReleaseStore()
        write_asset_fixtures(self.root, VERSION)
        self.adapter_patch = mock.patch.object(
            release, "GitHubCLI", return_value=self.github
        )
        self.adapter_patch.start()
        self.addCleanup(self.adapter_patch.stop)

    def run_publication(self):
        with contextlib.redirect_stdout(io.StringIO()):
            release.publish_assets(self.root, VERSION)

    def mutations(self):
        return [
            call
            for call in self.github.calls
            if call[0] in {"create_draft", "upload_assets", "publish_release"}
        ]

    def test_new_release_creates_verified_draft_before_publication(self):
        self.run_publication()
        self.assertEqual(
            self.mutations(), [("create_draft", TAG), ("publish_release", TAG, True)]
        )
        self.assertFalse(self.github.releases[TAG]["isDraft"])
        self.assertEqual(
            self.github.formulas[TAG], (self.root / "aviary.rb").read_text()
        )

    def test_existing_draft_resumes_upload_then_publication(self):
        self.github.add_release(VERSION, draft=True)
        self.github.releases[TAG]["assets"] = []
        self.run_publication()
        self.assertEqual(
            self.mutations(), [("upload_assets", TAG), ("publish_release", TAG, True)]
        )
        release.require_public_release(self.github.releases[TAG], VERSION)

    def test_public_retry_validates_without_upload_or_latest_mutation(self):
        self.run_publication()
        original = copy.deepcopy(self.github.releases[TAG])
        self.github.calls.clear()
        self.run_publication()
        self.assertEqual(self.mutations(), [])
        self.assertEqual(self.github.releases[TAG], original)
        self.assertNotIn(("list_releases",), self.github.calls)

    def test_public_formula_conflict_fails_without_mutation(self):
        self.github.add_release(VERSION, content=formula_contents(VERSION))
        with self.assertRaisesRegex(RuntimeError, "different formula metadata"):
            self.run_publication()
        self.assertEqual(self.mutations(), [])

    def test_incomplete_public_release_is_not_repaired_by_upload(self):
        self.github.add_release(VERSION)
        self.github.releases[TAG]["assets"] = [{"name": "aviary.rb"}]
        with self.assertRaisesRegex(RuntimeError, "missing assets"):
            self.run_publication()
        self.assertEqual(self.mutations(), [])

    def test_prerelease_draft_is_rejected_without_mutation(self):
        self.github.add_release(VERSION, draft=True, prerelease=True)
        with self.assertRaisesRegex(RuntimeError, "stable draft"):
            self.run_publication()
        self.assertEqual(self.mutations(), [])

    def test_older_completion_does_not_advance_latest(self):
        self.github.add_release("0.1.10")
        self.run_publication()
        self.assertEqual(self.mutations()[-1], ("publish_release", TAG, False))

    def test_reversed_release_completion_keeps_newer_latest(self):
        newer = self.root / "newer"
        newer.mkdir()
        write_asset_fixtures(newer, "0.1.10")
        with contextlib.redirect_stdout(io.StringIO()):
            release.publish_assets(newer, "0.1.10")
        self.run_publication()
        publications = [
            call for call in self.mutations() if call[0] == "publish_release"
        ]
        self.assertEqual(
            publications,
            [("publish_release", "v0.1.10", True), ("publish_release", TAG, False)],
        )

    def test_numeric_comparison_ignores_newer_drafts_and_prereleases(self):
        self.github.add_release("0.1.1")
        self.github.add_release("0.1.10", draft=True)
        self.github.add_release("1.0.0", prerelease=True)
        self.github.releases["nightly"] = {
            **release_record("9.0.0"),
            "tagName": "nightly",
        }
        self.run_publication()
        self.assertEqual(self.mutations()[-1], ("publish_release", TAG, True))

    def test_invalid_archive_checksum_prevents_github_actions(self):
        archive = next(self.root.glob("*.tar.gz"))
        archive.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            self.run_publication()
        self.assertEqual(self.github.calls, [])


class TapUpdateTests(unittest.TestCase):
    def setUp(self):
        self.run_command = release.run_command
        self.root = Path(tempfile.mkdtemp(prefix="aviary-tap-policy-"))
        self.checkout = self.root / "tap"
        self.checkout.mkdir()
        self.remote = self.root / "origin.git"
        self.git_env = dict(
            os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull
        )
        self.git_env.pop("GIT_DIR", None)
        self.git_env.pop("GIT_WORK_TREE", None)
        self.git("init", "--bare", "--initial-branch=main", str(self.remote))
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Tap fixture")
        self.git("config", "user.email", "tap@example.invalid")
        (self.checkout / "README.md").write_text("Tap fixture\n")
        self.git("add", ".")
        self.git("commit", "-m", "Initial tap fixture")
        self.git("remote", "add", "origin", TAP_URL)
        self.git("push", "-u", str(self.remote), "main")
        self.github = ReleaseStore()
        self.github.add_release(VERSION)
        self.tap_commands = []
        self.adapter_patch = mock.patch.object(
            release, "GitHubCLI", return_value=self.github
        )
        self.runner_patch = mock.patch.object(
            release, "run_command", side_effect=self.run_local
        )
        self.adapter_patch.start()
        self.runner_patch.start()
        self.addCleanup(self.adapter_patch.stop)
        self.addCleanup(self.runner_patch.stop)

    def git(self, *args, cwd=None):
        return self.run_command(
            ["git", *args], cwd=cwd or self.checkout, env=self.git_env
        ).stdout.strip()

    def run_local(self, args, **options):
        self.tap_commands.append(tuple(map(str, args)))
        if args[0] == "git" and args[1] in {"push", "fetch", "ls-remote"}:
            # Rewrite only transport operations. Origin inspection still sees the
            # real GitHub URL, while all pushes stay within the local fixture.
            args = ["git", "-c", f"url.{self.remote}.insteadOf={TAP_URL}", *args[1:]]
        return self.run_command(args, env=self.git_env, **options)

    def install_formula(self, content):
        path = self.checkout / "Formula/aviary.rb"
        path.parent.mkdir(exist_ok=True)
        path.write_text(content)
        self.git("add", "Formula/aviary.rb")
        self.git("commit", "-m", "Existing formula")
        self.git("push", str(self.remote), "main")
        return path

    def run_update(self, tap_dir=None):
        with contextlib.redirect_stdout(io.StringIO()):
            release.update_tap(VERSION, tap_dir=tap_dir or self.checkout)

    def assert_no_git_mutations(self):
        self.assertFalse(
            any(
                command[1] in {"add", "commit", "push", "tag"}
                for command in self.tap_commands
            ),
            self.tap_commands,
        )

    def test_newer_formula_advances_only_formula_and_pushes_local_remote(self):
        path = self.install_formula(formula_contents("0.1.1"))
        before = self.git("rev-parse", "HEAD")
        self.run_update()
        after = self.git("rev-parse", "HEAD")
        self.assertNotEqual(before, after)
        self.assertEqual(path.read_text(), self.github.formulas[TAG])
        self.assertEqual(
            self.git("diff", "--name-only", before, after), "Formula/aviary.rb"
        )
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(
            self.git("--git-dir", str(self.remote), "rev-parse", "refs/heads/main"),
            after,
        )
        self.assertEqual(
            self.git("log", "-1", "--format=%B"), f"Update aviary to {VERSION}"
        )
        self.assertFalse(any(command[0] != "git" for command in self.tap_commands))
        self.assertEqual(
            [call[0] for call in self.github.calls], ["get_release", "download_formula"]
        )
        self.assertEqual(
            [
                command
                for command in self.tap_commands
                if command[1] in {"add", "commit", "push"}
            ],
            [
                ("git", "add", "--", "Formula/aviary.rb"),
                ("git", "commit", "-m", f"Update aviary to {VERSION}"),
                ("git", "push", "origin", "HEAD"),
            ],
        )
        self.assertFalse(any("--force" in command for command in self.tap_commands))

    def test_missing_formula_bootstraps_clean_tap(self):
        self.run_update()
        self.assertEqual(
            (self.checkout / "Formula/aviary.rb").read_text(), self.github.formulas[TAG]
        )
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_default_update_clones_tap_without_release_mutations(self):
        cloned = []

        def clone(destination):
            self.git("clone", str(self.remote), str(destination))
            self.git("remote", "set-url", "origin", TAP_URL, cwd=destination)
            self.git("config", "user.name", "Tap fixture", cwd=destination)
            self.git("config", "user.email", "tap@example.invalid", cwd=destination)
            cloned.append(destination)

        self.github.clone_tap = mock.Mock(side_effect=clone)
        with contextlib.redirect_stdout(io.StringIO()):
            release.update_tap(VERSION)
        self.assertEqual(len(cloned), 1)
        self.assertEqual(
            (cloned[0] / "Formula/aviary.rb").read_text(), self.github.formulas[TAG]
        )
        self.assertEqual(self.git("status", "--porcelain", cwd=cloned[0]), "")
        self.assertEqual(
            [call[0] for call in self.github.calls], ["get_release", "download_formula"]
        )
        self.assertFalse(any(command[0] != "git" for command in self.tap_commands))

    def test_same_formula_is_no_op(self):
        self.install_formula(self.github.formulas[TAG])
        before = self.git("rev-parse", "HEAD")
        self.run_update()
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assert_no_git_mutations()

    def test_equal_version_with_different_bytes_fails_without_mutation(self):
        path = self.install_formula(self.github.formulas[TAG] + "# changed metadata\n")
        content, before = path.read_text(), self.git("rev-parse", "HEAD")
        with self.assertRaisesRegex(RuntimeError, "differs from its published formula"):
            self.run_update()
        self.assertEqual(path.read_text(), content)
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assert_no_git_mutations()

    def test_older_candidate_preserves_newer_tap(self):
        path = self.install_formula(formula_contents("0.1.10"))
        before = self.git("rev-parse", "HEAD")
        self.run_update()
        self.assertEqual(path.read_text(), formula_contents("0.1.10"))
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assert_no_git_mutations()

    def test_local_ahead_reverted_formula_cannot_downgrade_live_tap(self):
        path = self.install_formula(formula_contents("0.1.10"))
        remote_head = self.git("rev-parse", "HEAD")
        path.write_text(formula_contents("0.1.1"))
        self.git("add", "Formula/aviary.rb")
        self.git("commit", "-m", "Local unpushed formula revert")
        local_head = self.git("rev-parse", "HEAD")
        with self.assertRaises(RuntimeError):
            self.run_update()
        self.assertEqual(path.read_text(), formula_contents("0.1.1"))
        self.assertEqual(self.git("rev-parse", "HEAD"), local_head)
        self.assertEqual(
            self.git("--git-dir", str(self.remote), "rev-parse", "refs/heads/main"),
            remote_head,
        )
        self.assert_no_git_mutations()

    def test_detached_checkout_cannot_update_tap(self):
        self.install_formula(formula_contents("0.1.1"))
        before = self.git("rev-parse", "HEAD")
        self.git("checkout", "--detach", before)
        with self.assertRaises(RuntimeError):
            self.run_update()
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assert_no_git_mutations()

    def test_malformed_current_versions_fail_before_edits(self):
        contents = (
            "class Aviary < Formula\nend\n",
            '  version "0.1.1"\n  version "0.1.2"\n',
            '  version "0.1.01"\n',
            '  version "0.1.1-beta"\n',
            "  version ENV.fetch('VERSION')\n",
        )
        for content in contents:
            with self.subTest(content=content):
                path = self.install_formula(content)
                before = self.git("rev-parse", "HEAD")
                with self.assertRaises(ValueError):
                    self.run_update()
                self.assertEqual(path.read_text(), content)
                self.assertEqual(self.git("rev-parse", "HEAD"), before)
                self.assert_no_git_mutations()

    def test_dirty_tap_preserves_existing_changes(self):
        path = self.install_formula(formula_contents("0.1.1"))
        readme = self.checkout / "README.md"
        readme.write_text("Uncommitted local notes\n")
        self.git("add", "README.md")
        before = self.git("rev-parse", "HEAD")
        with self.assertRaisesRegex(RuntimeError, "Keep the tap checkout clean"):
            self.run_update()
        self.assertEqual(readme.read_text(), "Uncommitted local notes\n")
        self.assertEqual(path.read_text(), formula_contents("0.1.1"))
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "README.md")
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assert_no_git_mutations()

    def test_formula_must_match_published_tag_before_tap_edits(self):
        self.github.formulas[TAG] = formula_contents("0.1.3")
        before = self.git("rev-parse", "HEAD")
        with self.assertRaisesRegex(RuntimeError, "does not contain version"):
            self.run_update()
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assertFalse((self.checkout / "Formula/aviary.rb").exists())
        self.assert_no_git_mutations()


class PublishedVerificationTests(unittest.TestCase):
    def setUp(self):
        self.github = ReleaseStore()
        self.github.add_release(VERSION)
        self.github.tap = self.github.formulas[TAG]
        self.run = {
            "databaseId": 100,
            "conclusion": "success",
            "url": "https://example.invalid/run/100",
            "jobs": [
                {"name": "publish", "conclusion": "success", "databaseId": 101},
                {"name": "homebrew", "conclusion": "success", "databaseId": 102},
            ],
        }

    def verify(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return release.verify_published_release(self.github, VERSION, self.run)

    def test_current_release_and_formula_are_verified(self):
        self.assertEqual(self.verify(), self.github.releases[TAG])

    def test_historical_release_accepts_verified_newer_public_formula(self):
        self.github.add_release("0.1.10")
        self.github.tap = self.github.formulas["v0.1.10"]
        self.assertEqual(self.verify(), self.github.releases[TAG])
        self.assertIn(("get_release", "v0.1.10"), self.github.calls)
        self.assertIn(("download_formula", "v0.1.10"), self.github.calls)

    def test_newer_tap_with_different_bytes_is_not_verified(self):
        self.github.add_release("0.1.10")
        self.github.tap = self.github.formulas["v0.1.10"] + "# changed\n"
        with self.assertRaisesRegex(RuntimeError, "does not match release v0.1.10"):
            self.verify()

    def test_unpublished_newer_tap_is_not_verified(self):
        self.github.tap = formula_contents("0.1.10")
        with self.assertRaisesRegex(
            RuntimeError, "Expected a public stable release for v0.1.10"
        ):
            self.verify()

    def test_partial_homebrew_failure_has_tap_only_retry(self):
        self.github.tap = formula_contents("0.1.1")
        self.run["conclusion"] = "failure"
        self.run["jobs"][1]["conclusion"] = "failure"
        with self.assertRaisesRegex(RuntimeError, "--job 102") as raised:
            self.verify()
        self.assertIn("is public", str(raised.exception))
        self.assertNotIn("--failed", str(raised.exception))

    def test_tap_transport_errors_preserve_public_release_and_repair_guidance(self):
        errors = (
            RuntimeError("network unavailable"),
            OSError("transport unavailable"),
            subprocess.TimeoutExpired(["gh", "api"], 120),
        )
        for error in errors:
            with self.subTest(error=error):
                self.github.get_tap_formula = mock.Mock(side_effect=error)
                with self.assertRaisesRegex(
                    RuntimeError, "is public, but its Homebrew update is not verified"
                ) as raised:
                    self.verify()
                self.assertIn("--job 102", str(raised.exception))
                self.assertIs(raised.exception.__cause__, error)

    def test_historical_workflow_failure_uses_guarded_repair_command(self):
        self.github.tap = None
        self.run["jobs"] = []
        with self.assertRaisesRegex(RuntimeError, f"mise run repair-tap -- {VERSION}"):
            self.verify()

    def historical_tap_failure(self):
        self.run["conclusion"] = "failure"
        self.run["jobs"] = [
            {"name": "build (macos)", "conclusion": "success", "databaseId": 99},
            {
                "name": "publish",
                "conclusion": "failure",
                "databaseId": 101,
                "steps": [
                    {"name": "Prepare release", "conclusion": "success"},
                    {"name": "Publish release", "conclusion": "success"},
                    {"name": "Update Homebrew tap", "conclusion": "failure"},
                    {"name": "Post checkout", "conclusion": "success"},
                ],
            },
        ]

    def test_old_combined_publish_job_tap_failure_uses_guarded_repair(self):
        self.historical_tap_failure()
        self.github.tap = None
        with self.assertRaisesRegex(
            RuntimeError, f"mise run repair-tap -- {VERSION}"
        ) as raised:
            self.verify()
        self.assertIn("is public", str(raised.exception))
        self.assertNotIn("--job", str(raised.exception))
        self.assertNotIn("--failed", str(raised.exception))

    def test_old_combined_publish_job_verifies_after_external_tap_repair(self):
        self.historical_tap_failure()
        self.assertEqual(self.verify(), self.github.releases[TAG])

    def test_old_combined_job_with_other_failed_step_is_not_tap_only(self):
        self.historical_tap_failure()
        self.run["jobs"][1]["steps"][1]["conclusion"] = "failure"
        with self.assertRaisesRegex(RuntimeError, "--failed"):
            self.verify()
        self.assertEqual(self.github.calls, [])

    def test_successful_tap_repair_allows_failed_homebrew_run_resume(self):
        self.run["conclusion"] = "failure"
        self.run["jobs"][1]["conclusion"] = "failure"
        self.assertEqual(self.verify(), self.github.releases[TAG])

    def test_failed_publication_job_is_not_treated_as_tap_only_failure(self):
        self.run["conclusion"] = "failure"
        self.run["jobs"][0]["conclusion"] = "failure"
        self.github.releases.clear()
        with self.assertRaisesRegex(RuntimeError, "release.yml ended with failure"):
            self.verify()
        self.assertEqual(self.github.calls, [])


if __name__ == "__main__":
    unittest.main()
