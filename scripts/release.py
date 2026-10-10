#!/usr/bin/env -S uv run --no-project --python 3.14.8 python
"""Package, validate, and publish Aviary releases using the standard library."""

import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import tarfile
import tempfile
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from string import Template
from typing import Any
from urllib.parse import quote

Runner = Callable[..., subprocess.CompletedProcess[str]]
JsonObject = dict[str, Any]


def _check_result(result: subprocess.CompletedProcess[str]) -> None:
    if result.returncode:
        command = " ".join(map(str, result.args))
        output = f"{result.stdout or ''}{result.stderr or ''}".rstrip()
        raise RuntimeError(f"Command failed ({command}):\n{output}".rstrip())


def run_command(
    args: Sequence[str | Path],
    *,
    cwd: Path,
    timeout: float = 120,
    check: bool = True,
    stream: bool = False,
    env: Mapping[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run without interactive input; optionally inherit the terminal's output."""
    if timeout <= 0:
        raise ValueError("Command timeout must be positive")
    result = subprocess.run(
        [str(arg) for arg in args],
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        capture_output=not stream,
        text=True,
        timeout=timeout,
        check=False,
        env=env,
    )
    # Streamed commands have no captured output, but callers always receive strings.
    result = subprocess.CompletedProcess(
        result.args, result.returncode, result.stdout or "", result.stderr or ""
    )
    if check:
        _check_result(result)
    return result


class GitRepository:
    """Git operations scoped to one checkout."""

    def __init__(self, path: Path, runner: Runner | None = None) -> None:
        self.path = Path(path)
        self._runner = runner or run_command

    def run(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return self._runner(["git", *args], cwd=self.path, check=check)

    def text(self, *args: str) -> str:
        return self.run(*args).stdout.strip()

    def changed_paths(self) -> set[str]:
        """Include staged, unstaged, and untracked paths without parsing filenames."""
        paths: set[str] = set()
        for args in (
            ("diff", "--name-only", "HEAD", "-z"),
            ("diff", "--cached", "--name-only", "-z"),
            ("ls-files", "--others", "--exclude-standard", "-z"),
        ):
            paths.update(self.run(*args).stdout.split("\0"))
        paths.discard("")
        return paths

    def remote_tag_commit(self, tag: str) -> str | None:
        tag_ref = f"refs/tags/{tag}"
        peeled_ref = f"{tag_ref}^{{}}"
        lines = self.run(
            "ls-remote", "--tags", "origin", tag_ref, peeled_ref
        ).stdout.splitlines()
        refs = {}
        for line in lines:
            fields = line.split()
            if len(fields) != 2:
                raise RuntimeError("Invalid git ls-remote output")
            commit, ref = fields
            refs[ref] = commit
        return refs.get(peeled_ref, refs.get(tag_ref))

    def tag_exists(self, tag: str) -> bool:
        result = self.run(
            "show-ref", "--verify", "--quiet", f"refs/tags/{tag}", check=False
        )
        if result.returncode not in (0, 1):
            _check_result(result)
        return result.returncode == 0

    def require_clean(self, message: str) -> None:
        if self.text("status", "--porcelain=v1", "--untracked-files=all"):
            raise RuntimeError(message)


def _json(output: str, context: str) -> Any:
    try:
        return json.loads(output)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"Invalid JSON from {context}: {error.msg}") from error


def _object(value: Any, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise RuntimeError(f"Expected an object from {context}")
    return value


def _objects(value: Any, context: str) -> list[JsonObject]:
    if not isinstance(value, list):
        raise RuntimeError(f"Expected an array from {context}")
    return [_object(item, context) for item in value]


def _release(value: Any, context: str) -> JsonObject:
    release = _object(value, context)
    for key, expected_type in (
        ("tag_name", str),
        ("draft", bool),
        ("prerelease", bool),
        ("html_url", str),
    ):
        if not isinstance(release.get(key), expected_type):
            raise RuntimeError(f"Invalid release field {key} from {context}")
    assets = _objects(release.get("assets"), context)
    if any(not isinstance(asset.get("name"), str) for asset in assets):
        raise RuntimeError(f"Invalid release asset name from {context}")
    return {
        "tagName": release["tag_name"],
        "isDraft": release["draft"],
        "isPrerelease": release["prerelease"],
        "assets": assets,
        "url": release["html_url"],
    }


class GitHubCLI:
    """GitHub transport and response validation; publication policy lives elsewhere."""

    def __init__(
        self,
        repository: str,
        *,
        cwd: Path,
        runner: Runner | None = None,
        tap_repository: str = "grahamannett/homebrew-tap",
    ) -> None:
        self.repository = repository
        self.cwd = Path(cwd)
        self.tap_repository = tap_repository
        self._runner = runner or run_command

    def _run(
        self, *args: str, check: bool = True, timeout: float = 120
    ) -> subprocess.CompletedProcess[str]:
        return self._runner(["gh", *args], cwd=self.cwd, check=check, timeout=timeout)

    def _optional_api(self, endpoint: str, *args: str) -> str | None:
        result = self._run("api", endpoint, *args, check=False)
        if result.returncode:
            # gh's REST errors include the HTTP status in stderr. Authentication,
            # rate limits, transport failures, and malformed JSON are never absence.
            if re.search(r"\(HTTP 404\)", result.stderr or ""):
                return None
            _check_result(result)
        return result.stdout

    def check_auth(self) -> None:
        self._run("auth", "status")

    def secret_names(self) -> set[str]:
        output = self._run(
            "secret", "list", "--repo", self.repository, "--json", "name"
        ).stdout
        secrets = _objects(_json(output, "GitHub secrets"), "GitHub secrets")
        if any(not isinstance(secret.get("name"), str) for secret in secrets):
            raise RuntimeError("Invalid secret name from GitHub secrets")
        return {secret["name"] for secret in secrets}

    def list_runs(self, workflow: str, branch: str, commit: str) -> list[JsonObject]:
        output = self._run(
            "run",
            "list",
            "--repo",
            self.repository,
            "--workflow",
            workflow,
            "--event",
            "push",
            "--branch",
            branch,
            "--commit",
            commit,
            "--limit",
            "100",
            "--json",
            "databaseId,headSha,headBranch,event",
        ).stdout
        runs = _objects(_json(output, "GitHub workflow runs"), "GitHub workflow runs")
        for run in runs:
            self._validate_run(run)
        return runs

    def get_run(self, run_id: int) -> JsonObject:
        output = self._run(
            "run",
            "view",
            str(run_id),
            "--repo",
            self.repository,
            "--json",
            "databaseId,headSha,headBranch,event,status,conclusion,url,jobs",
        ).stdout
        run = _object(_json(output, "GitHub workflow run"), "GitHub workflow run")
        self._validate_run(run)
        if not isinstance(run.get("status"), str) or not isinstance(
            run.get("url"), str
        ):
            raise RuntimeError("Invalid workflow status or URL from GitHub")
        if run.get("conclusion") is not None and not isinstance(run["conclusion"], str):
            raise RuntimeError("Invalid workflow conclusion from GitHub")
        _objects(run.get("jobs"), "GitHub workflow jobs")
        return run

    @staticmethod
    def _validate_run(run: JsonObject) -> None:
        if type(run.get("databaseId")) is not int:
            raise RuntimeError("Invalid workflow run ID from GitHub")
        if any(
            not isinstance(run.get(key), str)
            for key in ("headSha", "headBranch", "event")
        ):
            raise RuntimeError("Invalid workflow metadata from GitHub")

    def get_release(self, tag: str) -> JsonObject | None:
        output = self._optional_api(
            f"repos/{self.repository}/releases/tags/{quote(tag, safe='')}"
        )
        if output is None:
            return None
        return _release(_json(output, "GitHub release"), "GitHub release")

    def list_releases(self) -> list[JsonObject]:
        output = self._run(
            "api",
            f"repos/{self.repository}/releases?per_page=100",
            "--paginate",
            "--slurp",
        ).stdout
        pages = _json(output, "GitHub releases")
        if not isinstance(pages, list):
            raise RuntimeError("Expected paginated arrays from GitHub releases")
        return [
            _release(release, "GitHub releases")
            for page in pages
            for release in _objects(page, "GitHub releases page")
        ]

    def create_draft(self, tag: str, assets: Sequence[Path]) -> None:
        self._run(
            "release",
            "create",
            tag,
            "--repo",
            self.repository,
            "--verify-tag",
            "--draft",
            "--title",
            f"Aviary {tag.removeprefix('v')}",
            "--generate-notes",
            *(str(asset) for asset in assets),
            timeout=300,
        )

    def upload_assets(self, tag: str, assets: Sequence[Path]) -> None:
        self._run(
            "release",
            "upload",
            tag,
            "--repo",
            self.repository,
            *(str(asset) for asset in assets),
            "--clobber",
            timeout=300,
        )

    def publish_release(self, tag: str, *, latest: bool) -> None:
        self._run(
            "release",
            "edit",
            tag,
            "--repo",
            self.repository,
            "--draft=false",
            f"--latest={str(latest).lower()}",
        )

    def download_formula(self, tag: str, destination: Path) -> Path:
        self._run(
            "release",
            "download",
            tag,
            "--repo",
            self.repository,
            "--pattern",
            "aviary.rb",
            "--dir",
            str(destination),
            timeout=300,
        )
        formula = destination / "aviary.rb"
        if not formula.is_file():
            raise RuntimeError(f"GitHub did not download the formula for {tag}")
        return formula

    def get_tap_formula(self) -> str | None:
        return self._optional_api(
            f"repos/{self.tap_repository}/contents/Formula/aviary.rb",
            "--header",
            "Accept: application/vnd.github.raw",
        )

    def clone_tap(self, destination: Path) -> None:
        self._run("repo", "clone", self.tap_repository, str(destination), timeout=300)


ARCHITECTURES = ("arm64", "x86_64")
PLATFORMS = ("macos", "linux")
SYSTEM_LIBRARIES = re.compile(
    r"^(?:ld-linux[^/]*|lib(?:c|m|pthread|rt|dl|resolv|util|anl)\.so(?:\..*)?)$"
)


@dataclass(frozen=True, slots=True)
class PackageOptions:
    """Inputs needed to build one platform's release archive."""

    build_dir: Path
    output_dir: Path
    version: str
    platform: str
    arch: str
    repository_dir: Path
    swift_runtime_license: Path | None = None


def version_number(value: str) -> str:
    version = value.removeprefix("v")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
        raise ValueError("Expected a semantic version, optionally prefixed with v")
    return version


def sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def read_checksums(path: Path) -> dict[str, str]:
    digests = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"([0-9a-fA-F]{64})\s+\*?([^/\s]+)", line)
        if not match:
            raise ValueError(f"Invalid checksum line: {line!r}")
        if match[2] in digests:
            raise ValueError(f"Duplicate checksum for {match[2]}")
        digests[match[2]] = match[1].lower()
    return digests


def run(*args: str) -> str:
    return run_command(args, cwd=Path.cwd()).stdout


def copyright_bearing_comments(content: str) -> set[str]:
    """Preserve license blocks wherever generated or conditional source places them."""
    comments = re.finditer(
        r"/\*.*?\*/|(?:^[ \t]*//[^\n]*(?:\n|$))+",
        content,
        re.MULTILINE | re.DOTALL,
    )
    return {match[0].strip() for match in comments if "copyright" in match[0].lower()}


def shared_libraries(binary: Path) -> dict[str, Path]:
    output = run("ldd", str(binary))
    if "not found" in output:
        raise RuntimeError(f"Unresolved dependencies of {binary}:\n{output}")
    libraries = {}
    for line in output.splitlines():
        match = re.match(r"\s*(\S+)\s+=>\s+(/[^ ]+)\s+\(", line)
        if match and not SYSTEM_LIBRARIES.fullmatch(match[1]):
            libraries[match[1]] = Path(match[2]).resolve()
    return libraries


def validate_executable(binary: Path, platform: str, arch: str) -> None:
    if platform == "linux":
        with binary.open("rb") as source:
            header = source.read(20)
        if len(header) != 20 or header[:6] != b"\x7fELF\x02\x01":
            raise RuntimeError(
                f"Expected a 64-bit little-endian Linux executable: {binary}"
            )
        machine = struct.unpack("<H", header[18:20])[0]
        if machine != {"arm64": 183, "x86_64": 62}[arch]:
            raise RuntimeError(
                f"Executable architecture does not match {arch}: {binary}"
            )
        return
    if run("lipo", "-archs", str(binary)).strip() != arch:
        raise RuntimeError(f"Executable architecture does not match {arch}: {binary}")
    load_commands = run("otool", "-l", str(binary))
    minimum = re.search(r"\bminos\s+(\d+)\.(\d+)", load_commands)
    if minimum and tuple(map(int, minimum.groups())) > (13, 0):
        raise RuntimeError(f"Executable requires macOS newer than 13.0: {binary}")
    for line in run("otool", "-L", str(binary)).splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if not dependency.startswith(("/usr/lib/", "/System/Library/", "@rpath/")):
            raise RuntimeError(
                f"macOS executable depends on a build-host library: {dependency}"
            )


def bundle_linux_dependencies(
    binaries: list[Path],
    destination: Path,
    notices: Path,
    swift_license: Path | None,
) -> list[str]:
    if not swift_license or not swift_license.is_file():
        raise RuntimeError(
            "Linux packaging requires --swift-runtime-license pointing to Swift's LICENSE.txt"
        )
    if not shutil.which("patchelf"):
        raise RuntimeError("Linux packaging requires patchelf")
    destination.mkdir()
    notices.mkdir(exist_ok=True)
    shutil.copy2(swift_license, notices / "swift-runtime-LICENSE.txt")
    pending = list(binaries)
    dependencies = {}
    while pending:
        for name, source in shared_libraries(pending.pop()).items():
            if name in dependencies:
                if dependencies[name] != source:
                    raise RuntimeError(f"Conflicting libraries named {name}")
                continue
            dependencies[name] = source
            pending.append(source)
    packages = set()
    for name, source in sorted(dependencies.items()):
        target = destination / name
        shutil.copy2(source, target)
        run("patchelf", "--set-rpath", "$ORIGIN", str(target))
        if (
            name.startswith("libswift")
            or name.startswith("libFoundation")
            or name.startswith("lib_InternalSwift")
        ):
            continue
        # Include the Ubuntu copyright files for redistributable system libraries.
        candidates = [str(source), str(source).replace("/usr/lib/", "/lib/", 1)]
        for candidate in candidates:
            result = subprocess.run(
                ["dpkg-query", "-S", candidate],
                capture_output=True,
                text=True,
                timeout=120,
            )
            if result.returncode == 0:
                packages.add(result.stdout.split(": ", 1)[0].split(":", 1)[0])
                break
        else:
            if "swift" not in str(source):
                raise RuntimeError(f"Cannot locate redistribution notice for {source}")
    for package in sorted(packages):
        copyright_file = Path("/usr/share/doc") / package / "copyright"
        if not copyright_file.is_file():
            raise RuntimeError(f"Missing license notice for {package}")
        shutil.copy2(copyright_file, notices / f"{package}-copyright.txt")
    for binary in binaries:
        run("patchelf", "--set-rpath", "$ORIGIN/../lib", str(binary))
    for binary in [*binaries, *destination.iterdir()]:
        for name, source in shared_libraries(binary).items():
            if source.parent != destination.resolve():
                raise RuntimeError(
                    f"Packaged {binary.name} still resolves {name} outside package: {source}"
                )
    return sorted(dependencies)


def package(args: PackageOptions) -> None:
    build = args.build_dir.resolve()
    repository = args.repository_dir.resolve()
    output = args.output_dir.resolve()
    version = version_number(args.version)
    name = f"aviary-{version}-{args.platform}-{args.arch}"
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"{name}.tar.gz"
    if archive.exists():
        raise FileExistsError(f"Refusing to overwrite {archive}")
    # Leave temporary artifacts for inspection; callers may remove them with trash.
    staging = Path(tempfile.mkdtemp(prefix=f"{name}-", dir=output))
    bin_dir = staging / "bin"
    bin_dir.mkdir()
    (staging / "libexec").mkdir()
    executables = []
    for source_name, target_name in [
        ("aviary", "aviary"),
        ("AviarySelfTest", "aviary-selftest"),
    ]:
        source = build / source_name
        if not source.is_file():
            raise FileNotFoundError(f"Build {source_name} before packaging: {source}")
        target = (
            bin_dir if target_name == "aviary" else staging / "libexec"
        ) / target_name
        shutil.copy2(source, target)
        target.chmod(0o755)
        validate_executable(target, args.platform, args.arch)
        executables.append(target)
    bundles = [
        p
        for p in build.iterdir()
        if p.is_dir() and p.name.endswith(("_XClient.bundle", "_XClient.resources"))
    ]
    if len(bundles) != 1:
        raise RuntimeError(
            f"Expected one XClient resource bundle in {build}; found {bundles}"
        )
    shutil.copytree(bundles[0], bin_dir / bundles[0].name)
    docs = staging / "share/doc/aviary"
    docs.mkdir(parents=True)
    shutil.copy2(repository / "THIRD_PARTY_NOTICES.md", docs)
    if (repository / "LICENSE").is_file():
        shutil.copy2(repository / "LICENSE", docs)
    dependencies_dir = docs / "dependencies"
    dependencies_dir.mkdir()
    shutil.copy2(repository / "licenses/Bird-LICENSE.txt", dependencies_dir)
    checkouts = repository / ".build/checkouts"
    for dependency in ("swift-argument-parser", "swift-crypto", "swift-asn1"):
        license_file = checkouts / dependency / "LICENSE.txt"
        if not license_file.is_file():
            raise RuntimeError(f"Missing resolved dependency license: {license_file}")
        shutil.copy2(license_file, dependencies_dir / f"{dependency}-LICENSE.txt")
        notice_file = checkouts / dependency / "NOTICE.txt"
        if notice_file.is_file():
            shutil.copy2(notice_file, dependencies_dir / f"{dependency}-NOTICE.txt")
    # Generated assembly can put preprocessor directives before its license.
    # Preserve complete copyright-bearing comments throughout vendored source.
    boring_ssl = checkouts / "swift-crypto/Sources/CCryptoBoringSSL"
    headers = set()
    for source in boring_ssl.rglob("*"):
        if source.is_file() and source.suffix in {
            ".c",
            ".cc",
            ".cpp",
            ".h",
            ".S",
            ".s",
            ".asm",
            ".inc",
        }:
            content = source.read_text(errors="replace")
            headers.update(copyright_bearing_comments(content))
    if not headers:
        raise RuntimeError("Cannot find vendored BoringSSL license headers")
    (dependencies_dir / "BoringSSL-NOTICES.txt").write_text(
        "\n\n".join(sorted(headers)) + "\n"
    )
    libraries = []
    if args.platform == "linux":
        libraries = bundle_linux_dependencies(
            executables, staging / "lib", dependencies_dir, args.swift_runtime_license
        )
    elif os.uname().sysname != "Darwin":
        raise RuntimeError("Package macOS releases on macOS")
    (docs / "release.json").write_text(
        json.dumps(
            {
                "version": version,
                "platform": args.platform,
                "architecture": args.arch,
                "libraries": libraries,
            },
            indent=2,
        )
        + "\n"
    )
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))

    def normalize(info: tarfile.TarInfo) -> tarfile.TarInfo:
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mtime = epoch
        return info

    with (
        archive.open("wb") as raw,
        gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=epoch) as compressed,
        tarfile.open(fileobj=compressed, mode="w") as tar,
    ):
        for path in sorted(staging.rglob("*")):
            tar.add(
                path,
                arcname=str(path.relative_to(staging)),
                recursive=False,
                filter=normalize,
            )
    digest = sha256(archive)
    (output / f"{archive.name}.sha256").write_text(f"{digest}  {archive.name}\n")
    print(archive)
    print(f"Staging tree retained at {staging}")


def collect(directory: Path, version: str) -> Path:
    version = version_number(version)
    lines = []
    for platform in PLATFORMS:
        for arch in ARCHITECTURES:
            name = f"aviary-{version}-{platform}-{arch}.tar.gz"
            expected = read_checksums(directory / f"{name}.sha256")
            if set(expected) != {name}:
                raise ValueError(f"Expected exactly one checksum for {name}")
            actual = sha256(directory / name)
            if expected[name] != actual:
                raise ValueError(f"Checksum mismatch for {name}")
            lines.append(f"{actual}  {name}\n")
    destination = directory / "SHA256SUMS"
    destination.write_text("".join(lines))
    print(destination)
    return destination


def check(archive: Path) -> None:
    root = Path(tempfile.mkdtemp(prefix="aviary-smoke-"))
    package = root / "relocated install with spaces"
    package.mkdir()
    with tarfile.open(archive, "r:gz") as tar:
        tar.extractall(package, filter="data")
    home = root / "empty-home"
    home.mkdir()
    work = root / "outside-checkout"
    work.mkdir()
    env = {
        k: v
        for k, v in os.environ.items()
        if k
        not in {
            "AUTH_TOKEN",
            "CT0",
            "BIRD_QUERY_IDS_CACHE",
            "AVIARY_QUERY_IDS_CACHE",
            "AVIARY_FEATURES_CACHE",
            "BIRD_FEATURES_CACHE",
            "LD_LIBRARY_PATH",
        }
    }
    env.update(
        HOME=str(home),
        XDG_CONFIG_HOME=str(home / ".config"),
        AVIARY_SKIP_QUERY_ID_REFRESH="1",
        NO_COLOR="1",
    )

    def run(binary: Path, *args: str, success: bool = True) -> str:
        result = subprocess.run(
            [str(binary), *args],
            cwd=work,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if (result.returncode == 0) != success:
            raise RuntimeError(
                f"Unexpected exit {result.returncode}: {binary} {' '.join(args)}\n{result.stdout}\n{result.stderr}"
            )
        return result.stdout

    binary = package / "bin/aviary"
    helper = package / "libexec/aviary-selftest"
    if "whoami" not in run(binary, "--help"):
        raise RuntimeError("Packaged --help does not list whoami")
    run(helper, "--resources-only")
    ids = json.loads(run(binary, "query-ids", "--json"))
    if not ids:
        raise RuntimeError("query-ids produced empty JSON")
    symlink_dir = root / "links"
    symlink_dir.mkdir()
    bird = symlink_dir / "bird"
    bird.symlink_to(binary)
    if json.loads(run(bird, "query-ids", "--json")) != ids:
        raise RuntimeError("Resource diagnostics changed through the bird symlink")
    renamed = package / "bin/bird"
    binary.rename(renamed)
    try:
        if json.loads(run(renamed, "query-ids", "--json")) != ids:
            raise RuntimeError(
                "Resource diagnostics changed after renaming aviary to bird"
            )
    finally:
        renamed.rename(binary)
    # Hide the shipped bundle. The diagnostic must fail even while source build resources exist.
    bundles = [
        p
        for p in (package / "bin").iterdir()
        if p.is_dir() and p.name.endswith(("_XClient.bundle", "_XClient.resources"))
    ]
    if len(bundles) != 1:
        raise RuntimeError(f"Expected exactly one shipped resource bundle: {bundles}")
    hidden = root / bundles[0].name
    bundles[0].rename(hidden)
    try:
        run(helper, "--resources-only", success=False)
    finally:
        hidden.rename(bundles[0])
    run(helper, "--resources-only")
    print(
        f"Release relocation, resources, missing-resource failure, symlink and rename checks passed: {archive}"
    )
    print(f"Smoke artifacts retained at {root}")


TEMPLATE_PATH = Path(__file__).resolve().parent / "templates" / "aviary.rb.in"


def render(
    version: str,
    checksums: Path,
    repository: str,
    base_url: str | None = None,
) -> str:
    """Render only after validating all required archive checksums and inputs."""
    version = version_number(version)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Expected repository owner/name")
    digests = read_checksums(checksums)
    base_url = (
        base_url or f"https://github.com/{repository}/releases/download/v{version}"
    )
    if any(c in base_url for c in ['"', "\n", "\r", "#{", "\\"]):
        raise ValueError("Unsafe formula URL")
    values = {
        "version": version,
        "repository": repository,
        "base_url": base_url.rstrip("/"),
    }
    for platform in PLATFORMS:
        for arch in ARCHITECTURES:
            filename = f"aviary-{version}-{platform}-{arch}.tar.gz"
            if filename not in digests:
                raise ValueError(
                    f"Missing checksum for {filename}; all four release archives are required"
                )
            values[f"{platform}_{arch}_sha256"] = digests[filename]
    return Template(TEMPLATE_PATH.read_text()).substitute(values)


def formula_version(content: str) -> str:
    """Read exactly one canonical stable version without interpreting Ruby."""
    declarations = re.findall(r"^[ \t]*version\b[^\n]*", content, re.MULTILINE)
    if len(declarations) != 1:
        raise ValueError("Expected exactly one literal version declaration in formula")
    match = re.fullmatch(r'[ \t]*version[ \t]+"([^"\n]+)"[ \t]*', declarations[0])
    if match is None:
        raise ValueError("Expected exactly one literal version declaration in formula")
    version = match[1]
    if not re.fullmatch(
        r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version
    ):
        raise ValueError("Expected canonical stable MAJOR.MINOR.PATCH in formula")
    return version


def prepare(
    directory: Path,
    version: str,
    repository: str = "grahamannett/aviary-swift",
) -> None:
    """Verify all platform archives and write checksums plus the binary formula."""
    directory = directory.resolve()
    checksums = collect(directory, version)
    output = directory / "aviary.rb"
    output.write_text(render(version, checksums, repository))
    print(output)


PUBLISH_REPOSITORY = "grahamannett/aviary-swift"
PUBLISH_VERSION_FILES = ("Sources/AviaryCLI/AviaryRoot.swift", "mise.test.toml")
PUBLISH_DISCOVERY_TIMEOUT = 300
PUBLISH_WORKFLOW_TIMEOUT = 3600
PUBLISH_POLL_INTERVAL = 10
REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
STABLE_VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")


def stable_version(value: str) -> str:
    """Publication accepts canonical stable versions, independently of packaging."""
    version = value.removeprefix("v")
    if not STABLE_VERSION.fullmatch(version):
        raise ValueError(
            "Release version must be MAJOR.MINOR.PATCH, optionally prefixed with v"
        )
    return version


def version_key(version: str) -> tuple[int, ...]:
    return tuple(map(int, stable_version(version).split(".")))


def expected_assets(version: str) -> set[str]:
    return {
        f"aviary-{version}-{platform}-{arch}.tar.gz"
        for platform in PLATFORMS
        for arch in ARCHITECTURES
    } | {"SHA256SUMS", "aviary.rb"}


def require_public_release(
    release: dict[str, Any] | None, version: str
) -> dict[str, Any]:
    tag = f"v{version}"
    if (
        release is None
        or release.get("tagName") != tag
        or release.get("isDraft") is not False
        or release.get("isPrerelease") is not False
    ):
        raise RuntimeError(f"Expected a public stable release for {tag}")
    missing = expected_assets(version) - {
        asset["name"] for asset in release.get("assets", [])
    }
    if missing:
        raise RuntimeError(
            f"Release {tag} is missing assets: {', '.join(sorted(missing))}"
        )
    return release


def published_formula(github: GitHubCLI, version: str) -> str:
    """Download immutable metadata and verify that it describes the requested tag."""
    require_public_release(github.get_release(f"v{version}"), version)
    downloaded = Path(tempfile.mkdtemp(prefix=f"aviary-published-{version}-"))
    content = github.download_formula(f"v{version}", downloaded).read_text()
    if formula_version(content) != version:
        raise RuntimeError(f"Published formula does not contain version {version}")
    return content


def publish_assets(
    directory: Path, version: str, repository: str = PUBLISH_REPOSITORY
) -> None:
    """Only drafts may receive uploads; public releases are immutable on retries."""
    version = stable_version(version)
    directory = directory.resolve()
    prepare(directory, version, repository)
    github = GitHubCLI(repository, cwd=REPOSITORY_ROOT)
    tag = f"v{version}"
    existing = github.get_release(tag)
    if existing is not None and not existing["isDraft"]:
        require_public_release(existing, version)
        if published_formula(github, version) != (directory / "aviary.rb").read_text():
            raise RuntimeError(
                f"Public {tag} has different formula metadata; refusing to overwrite it"
            )
        print(f"Already published: {existing['url']}", flush=True)
        return
    if existing is not None and existing["isPrerelease"]:
        raise RuntimeError(f"Expected a stable draft for {tag}")
    assets = [directory / name for name in sorted(expected_assets(version))]
    if existing is None:
        github.create_draft(tag, assets)
    else:
        github.upload_assets(tag, assets)
    other_versions = []
    for release in github.list_releases():
        other_tag = release["tagName"]
        if (
            release["isDraft"]
            or release["isPrerelease"]
            or other_tag == tag
            or not other_tag.startswith("v")
            or not STABLE_VERSION.fullmatch(other_tag[1:])
        ):
            continue
        other_versions.append(version_key(other_tag))
    latest = not other_versions or version_key(version) > max(other_versions)
    github.publish_release(tag, latest=latest)
    published = require_public_release(github.get_release(tag), version)
    print(
        f"Published {tag} (latest={str(latest).lower()}): {published['url']}",
        flush=True,
    )


def require_origin(git: GitRepository, repository: str) -> None:
    allowed = {
        f"https://github.com/{repository}",
        f"https://github.com/{repository}.git",
        f"git@github.com:{repository}",
        f"git@github.com:{repository}.git",
        f"ssh://git@github.com/{repository}",
        f"ssh://git@github.com/{repository}.git",
    }
    for options in (("--all",), ("--push", "--all")):
        origins = git.text("remote", "get-url", *options, "origin").splitlines()
        if not origins or any(origin not in allowed for origin in origins):
            raise RuntimeError(
                f"Expected every origin fetch and push URL to be {repository}"
            )


def update_tap(
    version: str, *, tap_dir: Path | None = None, repository: str = PUBLISH_REPOSITORY
) -> None:
    """Advance the tap monotonically using the formula attached to a public release."""
    version = stable_version(version)
    github = GitHubCLI(repository, cwd=REPOSITORY_ROOT)
    candidate = published_formula(github, version)
    if tap_dir is None:
        retained = Path(tempfile.mkdtemp(prefix=f"aviary-tap-{version}-"))
        tap_dir = retained / "checkout"
        github.clone_tap(tap_dir)
        print(f"Tap checkout retained at {tap_dir}", flush=True)
    tap_dir = tap_dir.resolve()
    git = GitRepository(tap_dir, runner=run_command)
    if Path(git.text("rev-parse", "--show-toplevel")).resolve() != tap_dir:
        raise RuntimeError("--tap-dir must name the tap checkout root")
    require_origin(git, github.tap_repository)
    git.require_clean("Keep the tap checkout clean before updating its formula")
    remote_head = git.run("ls-remote", "--symref", "origin", "HEAD").stdout
    branches = re.findall(r"^ref: refs/heads/(.+)\s+HEAD$", remote_head, re.MULTILINE)
    if len(branches) != 1:
        raise RuntimeError("Could not determine the tap's remote default branch")
    branch = branches[0]
    if git.text("branch", "--show-current") != branch:
        raise RuntimeError(f"Update the tap from its default branch {branch}")
    git.run("fetch", "origin", branch)
    if git.text("rev-parse", "HEAD") != git.text("rev-parse", "FETCH_HEAD"):
        raise RuntimeError(
            "Tap checkout differs from the live default branch; use a fresh checkout"
        )
    path = tap_dir / "Formula/aviary.rb"
    current = path.read_text() if path.exists() else None
    if current is not None:
        current_version = formula_version(current)
        if version_key(current_version) > version_key(version):
            print(
                f"Tap already contains newer version {current_version}; skipping {version}.",
                flush=True,
            )
            return
        if current_version == version:
            if current != candidate:
                raise RuntimeError(
                    f"Tap version {version} differs from its published formula"
                )
            print(f"Tap already matches version {version}.", flush=True)
            return
    initial_head = git.text("rev-parse", "HEAD")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(candidate)
    if git.text("rev-parse", "HEAD") != initial_head or git.changed_paths() != {
        "Formula/aviary.rb"
    }:
        raise RuntimeError(
            "Tap checkout changed during the update; inspect it before retrying"
        )
    git.run("add", "--", "Formula/aviary.rb")
    if set(git.run("diff", "--cached", "--name-only", "-z").stdout.split("\0")) - {
        ""
    } != {"Formula/aviary.rb"}:
        raise RuntimeError(
            "The tap index contains unrelated changes; no commit was created"
        )
    git.run("commit", "-m", f"Update aviary to {version}")
    git.run("push", "origin", "HEAD")
    print(f"Homebrew tap updated to {version}.", flush=True)


def version_file_pattern(path: str) -> re.Pattern[str]:
    if path == PUBLISH_VERSION_FILES[0]:
        return re.compile(r'(^[ \t]*version:[ \t]*")([^"]+)(")', re.MULTILINE)
    if path == PUBLISH_VERSION_FILES[1]:
        return re.compile(
            r"(^[ \t]*version[ \t]*=[^\n]*default\(value=')([^']+)('\))", re.MULTILINE
        )
    raise ValueError(f"Unsupported version file: {path}")


def version_in_contents(content: str, path: str) -> str:
    matches = list(version_file_pattern(path).finditer(content))
    if len(matches) != 1:
        raise RuntimeError(f"Expected exactly one version in {path}")
    return stable_version(matches[0][2])


def bump_version_contents(content: str, path: str, version: str) -> str:
    version_in_contents(content, path)
    return version_file_pattern(path).sub(
        lambda match: match[1] + version + match[3], content
    )


@dataclass(frozen=True)
class VersionEdit:
    path: str
    before: str
    after: str


def check_tag(git: GitRepository, tag: str, candidate: str, version: str) -> None:
    if git.text("cat-file", "-t", f"refs/tags/{tag}") != "tag":
        raise RuntimeError(f"{tag} must be an annotated tag")
    if git.text("rev-parse", f"refs/tags/{tag}^{{commit}}") != candidate:
        raise RuntimeError(f"Existing {tag} does not match the release candidate")
    for path in PUBLISH_VERSION_FILES:
        if (
            version_in_contents(git.run("show", f"{candidate}:{path}").stdout, path)
            != version
        ):
            raise RuntimeError(f"Tagged {path} does not contain version {version}")


def check_index_versions(git: GitRepository, edits: list[VersionEdit]) -> None:
    for edit in edits:
        entries = git.run("ls-files", "--stage", "--", edit.path).stdout.splitlines()
        head_entry = git.run("ls-tree", "HEAD", "--", edit.path).stdout.split()
        if len(entries) != 1 or not head_entry:
            raise RuntimeError(f"Unexpected index entry for {edit.path}")
        mode, _, stage = entries[0].split("\t", 1)[0].split()
        if mode != head_entry[0] or stage != "0":
            raise RuntimeError(
                f"Unexpected staged mode or merge conflict in {edit.path}"
            )
        if git.run("show", f":{edit.path}").stdout not in {edit.before, edit.after}:
            raise RuntimeError(
                f"Unexpected staged edits in {edit.path}; preserve them in a separate commit"
            )


def check_version_edits(
    git: GitRepository, edits: list[VersionEdit], *, completed: bool = False
) -> None:
    if git.changed_paths() - set(PUBLISH_VERSION_FILES):
        raise RuntimeError("Resume permits only the two release version edits")
    if git.text("diff", "HEAD", "--summary"):
        raise RuntimeError(
            "Resume permits version substitutions, not file mode or path changes"
        )
    for edit in edits:
        allowed = {edit.after} if completed else {edit.before, edit.after}
        if (git.path / edit.path).read_text() not in allowed:
            raise RuntimeError(
                f"Unexpected edits in {edit.path}; preserve them in a separate commit"
            )
    check_index_versions(git, edits)


def commit_version(
    git: GitRepository, version: str, initial_head: str, edits: list[VersionEdit]
) -> None:
    print("Updating the CLI version and installer-test default...", flush=True)
    for edit in edits:
        path = git.path / edit.path
        if path.read_text() != edit.after:
            path.write_text(edit.after)
    print("Running mise run ci...", flush=True)
    run_command(
        ["mise", "run", "ci"],
        cwd=git.path,
        timeout=PUBLISH_WORKFLOW_TIMEOUT,
        stream=True,
    )
    if (
        git.text("rev-parse", "HEAD") != initial_head
        or git.text("branch", "--show-current") != "main"
    ):
        raise RuntimeError(
            "HEAD changed during release checks; no release commit was created"
        )
    check_version_edits(git, edits, completed=True)
    if git.changed_paths():
        git.run("add", "--", *PUBLISH_VERSION_FILES)
        staged = set(
            git.run("diff", "--cached", "--name-only", "-z").stdout.split("\0")
        ) - {""}
        if staged - set(PUBLISH_VERSION_FILES):
            raise RuntimeError(
                "The index contains unrelated changes; no release commit was created"
            )
        git.run("commit", "-m", f"Release Aviary {version}")
    else:
        print(
            "Version edits are already committed; using the current commit.", flush=True
        )


def workflow_failure(
    workflow: str, run: dict[str, Any], repository: str
) -> RuntimeError:
    return RuntimeError(
        f"{workflow} ended with {run.get('conclusion')}: {run['url']}\n"
        f"After correcting the failure, rerun explicitly:\n"
        f"gh run rerun {run['databaseId']} --failed --repo {repository}"
    )


def wait_for_workflow(
    github: GitHubCLI,
    workflow: str,
    branch: str,
    commit: str,
    *,
    require_success: bool = True,
) -> dict[str, Any]:
    """Observe only the push run for the captured commit and branch or tag."""
    discovery_deadline = time.monotonic() + PUBLISH_DISCOVERY_TIMEOUT
    while True:
        matching = [
            item
            for item in github.list_runs(workflow, branch, commit)
            if item.get("headSha") == commit
            and item.get("headBranch") == branch
            and item.get("event") == "push"
        ]
        if matching:
            run_id = max(item["databaseId"] for item in matching)
            print(
                f"Observing {workflow}: https://github.com/{github.repository}/actions/runs/{run_id}",
                flush=True,
            )
            break
        if time.monotonic() >= discovery_deadline:
            raise RuntimeError(
                f"No {workflow} push run appeared for {commit} on {branch}"
            )
        time.sleep(PUBLISH_POLL_INTERVAL)
    finish_deadline = time.monotonic() + PUBLISH_WORKFLOW_TIMEOUT
    previous_status = None
    while True:
        run = github.get_run(run_id)
        if (
            run.get("databaseId") != run_id
            or run.get("headSha") != commit
            or run.get("headBranch") != branch
            or run.get("event") != "push"
        ):
            raise RuntimeError(
                f"Workflow {run_id} does not match the release candidate"
            )
        status = run["status"]
        if status != previous_status:
            print(f"{workflow}: {status}", flush=True)
            previous_status = status
        if status == "completed":
            if require_success and run.get("conclusion") != "success":
                raise workflow_failure(workflow, run, github.repository)
            return run
        if time.monotonic() >= finish_deadline:
            raise RuntimeError(f"Timed out waiting for {workflow}: {run['url']}")
        time.sleep(PUBLISH_POLL_INTERVAL)


def tap_repair_guidance(github: GitHubCLI, version: str, run: dict[str, Any]) -> str:
    job = next(
        (job for job in run.get("jobs", []) if job.get("name") == "homebrew"), None
    )
    if job is not None and type(job.get("databaseId")) is int:
        return f"gh run rerun {run['databaseId']} --job {job['databaseId']} --repo {github.repository}"
    return f"mise run repair-tap -- {version}"


def only_tap_failed(run: dict[str, Any]) -> bool:
    """Recognize a failed tap job, including the former combined publish job."""
    jobs = run.get("jobs", [])
    if not jobs:
        return False
    tap_failed = False
    for job in jobs:
        if job.get("conclusion") == "success":
            continue
        if job.get("name") == "homebrew":
            tap_failed = True
            continue
        steps = job.get("steps", [])
        tap_steps = [
            step for step in steps if step.get("name") == "Update Homebrew tap"
        ]
        if (
            job.get("name") == "publish"
            and tap_steps
            and all(
                step.get("conclusion") in {"success", "skipped"}
                for step in steps
                if step not in tap_steps
            )
            and any(step.get("conclusion") != "success" for step in tap_steps)
        ):
            tap_failed = True
            continue
        return False
    return tap_failed


def verify_published_release(
    github: GitHubCLI, version: str, workflow_run: dict[str, Any]
) -> dict[str, Any]:
    """Check immutable release metadata and the live tap, including historical resumes."""
    tag = f"v{version}"
    # A separate failed Homebrew job can be repaired without repeating publication.
    if workflow_run.get("conclusion") != "success" and not only_tap_failed(
        workflow_run
    ):
        raise workflow_failure("release.yml", workflow_run, github.repository)
    release = require_public_release(github.get_release(tag), version)
    candidate = published_formula(github, version)
    try:
        tap = github.get_tap_formula()
        if tap is None:
            raise RuntimeError("Homebrew's Formula/aviary.rb is missing")
        tap_version = formula_version(tap)
        if version_key(tap_version) < version_key(version):
            raise RuntimeError(f"Homebrew still contains older version {tap_version}")
        expected = (
            candidate
            if tap_version == version
            else published_formula(github, tap_version)
        )
        if tap != expected:
            raise RuntimeError(
                f"Homebrew's Formula/aviary.rb does not match release v{tap_version}"
            )
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(
            f"Release {tag} is public, but its Homebrew update is not verified: {error}\n"
            f"Check HOMEBREW_TAP_TOKEN, then repair explicitly:\n{tap_repair_guidance(github, version, workflow_run)}"
        ) from error
    print(f"Released {version}: {release['url']}", flush=True)
    print(f"Homebrew formula matches the published release v{tap_version}.", flush=True)
    print(f"Install: mise use -g github:{github.repository}@{version}", flush=True)
    return release


def observe_release(github: GitHubCLI, version: str, candidate: str) -> dict[str, Any]:
    run = wait_for_workflow(
        github, "release.yml", f"v{version}", candidate, require_success=False
    )
    return verify_published_release(github, version, run)


def publish(
    version: str, *, resume: bool = False, repository_dir: Path | None = None
) -> dict[str, Any]:
    """Commit a scoped version bump, gate its tag on CI, and observe publication."""
    version = stable_version(version)
    repository = Path(repository_dir or REPOSITORY_ROOT).resolve()
    git = GitRepository(repository, runner=run_command)
    github = GitHubCLI(PUBLISH_REPOSITORY, cwd=repository)
    tag = f"v{version}"
    try:
        print(f"Checking release prerequisites for {tag}...", flush=True)
        for tool in ("git", "gh", "mise"):
            if not shutil.which(tool):
                raise RuntimeError(f"Publishing requires {tool} on PATH")
        if git.text("branch", "--show-current") != "main":
            raise RuntimeError("Publish from the main branch")
        require_origin(git, PUBLISH_REPOSITORY)
        if not resume:
            git.require_clean(
                "Commit feature changes first; the checkout must be clean"
            )
        github.check_auth()
        if "HOMEBREW_TAP_TOKEN" not in github.secret_names():
            raise RuntimeError("Register HOMEBREW_TAP_TOKEN before publishing")
        git.run("fetch", "origin", "main", "--tags")
        if git.run(
            "merge-base", "--is-ancestor", "origin/main", "HEAD", check=False
        ).returncode:
            raise RuntimeError(
                "main has diverged from origin/main; reconcile it before publishing"
            )
        remote_candidate = git.remote_tag_commit(tag)
        local_tag = git.tag_exists(tag)
        if (remote_candidate or local_tag) and not resume:
            raise RuntimeError(
                f"{tag} already exists; use --resume to inspect this release"
            )
        if remote_candidate:
            git.require_clean("Keep the checkout clean while resuming a published tag")
            check_tag(git, tag, remote_candidate, version)
            if git.run(
                "merge-base",
                "--is-ancestor",
                remote_candidate,
                "origin/main",
                check=False,
            ).returncode:
                raise RuntimeError(f"Remote {tag} is not part of origin/main")
            print(f"Resuming existing {tag} at {remote_candidate}...", flush=True)
            wait_for_workflow(github, "ci.yml", "main", remote_candidate)
            return observe_release(github, version, remote_candidate)
        existing_versions = [
            version_key(item)
            for item in git.text("tag", "--list").splitlines()
            if item.startswith("v")
            and STABLE_VERSION.fullmatch(item[1:])
            and item != tag
        ]
        requested = version_key(version)
        if existing_versions and requested <= max(existing_versions):
            raise RuntimeError(
                "Choose a version newer than existing stable release tags"
            )
        initial_head = git.text("rev-parse", "HEAD")
        edits = []
        for path in PUBLISH_VERSION_FILES:
            before = git.run("show", f"HEAD:{path}").stdout
            edits.append(
                VersionEdit(path, before, bump_version_contents(before, path, version))
            )
        current_version = version_in_contents(edits[0].before, edits[0].path)
        if requested < version_key(current_version):
            raise RuntimeError(
                f"Cannot downgrade the CLI version from {current_version} to {version}"
            )
        check_version_edits(git, edits)
        if local_tag:
            check_tag(git, tag, initial_head, version)
            git.require_clean(
                "An existing tag requires a clean matching release commit"
            )
        else:
            commit_version(git, version, initial_head, edits)
        candidate = git.text("rev-parse", "HEAD")
        if git.text("rev-parse", "origin/main") != candidate:
            print(f"Pushing main at {candidate}...", flush=True)
            git.run("push", "origin", "main")
        print("Waiting for main CI for this exact commit...", flush=True)
        wait_for_workflow(github, "ci.yml", "main", candidate)
        if (
            git.text("rev-parse", "HEAD") != candidate
            or git.text("branch", "--show-current") != "main"
        ):
            raise RuntimeError(
                "The checkout changed while waiting for CI; no tag was pushed"
            )
        git.require_clean(
            "The checkout changed while waiting for CI; no tag was pushed"
        )
        if git.remote_tag_commit(tag):
            raise RuntimeError(
                f"Remote {tag} appeared during CI; inspect it with --resume"
            )
        if local_tag:
            check_tag(git, tag, candidate, version)
        else:
            print(f"Creating annotated {tag} at {candidate}...", flush=True)
            git.run("tag", "-a", tag, candidate, "-m", f"Aviary {version}")
        git.run("push", "origin", f"refs/tags/{tag}")
        print(
            "Waiting for native builds, publication, and the Homebrew update...",
            flush=True,
        )
        return observe_release(github, version, candidate)
    except (
        RuntimeError,
        OSError,
        ValueError,
        subprocess.TimeoutExpired,
        KeyboardInterrupt,
    ):
        print(
            f"Release stopped; existing edits, commits, and tags were retained.\n"
            f"After resolving the reported issue: mise run release -- {version} --resume",
            flush=True,
        )
        raise


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    package_parser = commands.add_parser(
        "package", help="Package prebuilt executables and resources"
    )
    package_parser.add_argument("--build-dir", type=Path, required=True)
    package_parser.add_argument("--output-dir", type=Path, required=True)
    package_parser.add_argument("--version", required=True)
    package_parser.add_argument("--platform", choices=PLATFORMS, required=True)
    package_parser.add_argument("--arch", choices=ARCHITECTURES, required=True)
    package_parser.add_argument("--repository-dir", type=Path, default=REPOSITORY_ROOT)
    package_parser.add_argument("--swift-runtime-license", type=Path)
    prepare_parser = commands.add_parser(
        "prepare", help="Verify four archives and generate release metadata"
    )
    prepare_parser.add_argument("directory", type=Path)
    prepare_parser.add_argument("version")
    prepare_parser.add_argument("--repository", default=PUBLISH_REPOSITORY)
    check_parser = commands.add_parser(
        "check", help="Check resources, relocation, and bird compatibility"
    )
    check_parser.add_argument("archive", type=Path)
    publish_parser = commands.add_parser(
        "publish", help="Bump, check, commit, tag, and observe a stable release"
    )
    publish_parser.add_argument("version")
    publish_parser.add_argument("--resume", action="store_true")
    assets_parser = commands.add_parser(
        "publish-assets",
        help="Publish verified assets without changing public releases",
    )
    assets_parser.add_argument("directory", type=Path)
    assets_parser.add_argument("version")
    assets_parser.add_argument("--repository", default=PUBLISH_REPOSITORY)
    tap_parser = commands.add_parser(
        "update-tap", help="Advance the tap using a published formula"
    )
    tap_parser.add_argument("version")
    tap_parser.add_argument("--tap-dir", type=Path)
    tap_parser.add_argument("--repository", default=PUBLISH_REPOSITORY)
    return parser


def main(argv: list[str] | None = None) -> None:
    parser = argument_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "package":
            package(
                PackageOptions(
                    build_dir=args.build_dir,
                    output_dir=args.output_dir,
                    version=args.version,
                    platform=args.platform,
                    arch=args.arch,
                    repository_dir=args.repository_dir,
                    swift_runtime_license=args.swift_runtime_license,
                )
            )
        elif args.command == "prepare":
            prepare(args.directory, args.version, args.repository)
        elif args.command == "check":
            check(args.archive.resolve())
        elif args.command == "publish":
            publish(args.version, resume=args.resume)
        elif args.command == "publish-assets":
            publish_assets(args.directory, args.version, args.repository)
        elif args.command == "update-tap":
            update_tap(args.version, tap_dir=args.tap_dir, repository=args.repository)
    except KeyboardInterrupt:
        parser.exit(130, "Release interrupted.\n")
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
