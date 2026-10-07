#!/usr/bin/env -S uv run --no-project --python 3.14 python
"""Package Aviary, prepare verified release metadata, and check relocated archives."""

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
from pathlib import Path

SYSTEM_LIBRARIES = re.compile(
    r"^(?:ld-linux[^/]*|lib(?:c|m|pthread|rt|dl|resolv|util|anl)\.so(?:\..*)?)$"
)
PLATFORMS = ("macos", "linux")
ARCHITECTURES = ("arm64", "x86_64")


def version_number(value):
    version = value.removeprefix("v")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
        raise ValueError("Expected a semantic version, optionally prefixed with v")
    return version


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def read_checksums(path):
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


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def copyright_bearing_comments(content):
    """Preserve license blocks wherever generated or conditional source places them."""
    comments = re.finditer(
        r"/\*.*?\*/|(?:^[ \t]*//[^\n]*(?:\n|$))+",
        content,
        re.MULTILINE | re.DOTALL,
    )
    return {match[0].strip() for match in comments if "copyright" in match[0].lower()}


def shared_libraries(binary):
    output = run("ldd", str(binary))
    if "not found" in output:
        raise RuntimeError(f"Unresolved dependencies of {binary}:\n{output}")
    libraries = {}
    for line in output.splitlines():
        match = re.match(r"\s*(\S+)\s+=>\s+(/[^ ]+)\s+\(", line)
        if match and not SYSTEM_LIBRARIES.fullmatch(match[1]):
            libraries[match[1]] = Path(match[2]).resolve()
    return libraries


def validate_executable(binary, platform, arch):
    if platform == "linux":
        with binary.open("rb") as source:
            header = source.read(20)
        if header[:6] != b"\x7fELF\x02\x01":
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


def bundle_linux_dependencies(binaries, destination, notices, swift_license):
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
                ["dpkg-query", "-S", candidate], capture_output=True, text=True
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


def package(args):
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

    def normalize(info):
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


def collect(directory, version):
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


def render(version, checksums, repository, base_url=None):
    version = version_number(version)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Expected repository owner/name")
    digests = read_checksums(checksums)
    base_url = (
        base_url or f"https://github.com/{repository}/releases/download/v{version}"
    )
    if any(c in base_url for c in ['"', "\n", "\r", "#{", "\\"]):
        raise ValueError("Unsafe formula URL")
    lines = [
        "# Generated by scripts/release.py prepare; update from verified release archives.",
        "class Aviary < Formula",
        '  desc "Bird-compatible CLI for reading and posting on X"',
        f'  homepage "https://github.com/{repository}"',
        f'  version "{version}"',
        "",
    ]
    for os_name in PLATFORMS:
        lines.append(f"  on_{os_name} do")
        if os_name == "macos":
            lines.append("    depends_on macos: :ventura")
        for arch in ARCHITECTURES:
            filename = f"aviary-{version}-{os_name}-{arch}.tar.gz"
            if filename not in digests:
                raise ValueError(
                    f"Missing checksum for {filename}; all four release archives are required"
                )
            lines.extend(
                [
                    f"    on_{'arm' if arch == 'arm64' else 'intel'} do",
                    f'      url "{base_url.rstrip("/")}/{filename}"',
                    f'      sha256 "{digests[filename]}"',
                    "    end",
                ]
            )
        lines.extend(["  end", ""])
    lines.extend(
        [
            "  def install",
            '    libexec.install Dir["*"]',
            '    bin.install_symlink libexec/"bin/aviary"',
            "  end",
            "",
            "  test do",
            '    ENV["AVIARY_SKIP_QUERY_ID_REFRESH"] = "1"',
            '    ENV["XDG_CONFIG_HOME"] = (testpath/"config").to_s',
            '    assert_match "whoami", shell_output("#{bin}/aviary --help")',
            '    assert_match "ok ", shell_output("#{libexec}/libexec/aviary-selftest --resources-only")',
            '    assert_match \'"features"\', shell_output("#{bin}/aviary query-ids --json")',
            "  end",
            "end",
            "",
        ]
    )
    return "\n".join(lines)


def check(archive):
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

    def run(binary, *args, success=True):
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


def prepare(directory, version, repository="grahamannett/aviary-swift"):
    """Verify all platform archives and write checksums plus the binary formula."""
    directory = directory.resolve()
    checksums = collect(directory, version)
    output = directory / "aviary.rb"
    output.write_text(render(version, checksums, repository))
    print(output)


def main(argv=None):
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
    package_parser.add_argument(
        "--repository-dir", type=Path, default=Path(__file__).resolve().parent.parent
    )
    package_parser.add_argument("--swift-runtime-license", type=Path)
    prepare_parser = commands.add_parser(
        "prepare", help="Verify four archives and generate release metadata"
    )
    prepare_parser.add_argument("directory", type=Path)
    prepare_parser.add_argument("version")
    prepare_parser.add_argument("--repository", default="grahamannett/aviary-swift")
    check_parser = commands.add_parser(
        "check", help="Check resources, relocation, and bird compatibility"
    )
    check_parser.add_argument("archive", type=Path)
    args = parser.parse_args(argv)
    if args.command == "package":
        package(args)
    elif args.command == "prepare":
        prepare(args.directory, args.version, args.repository)
    else:
        check(args.archive.resolve())


if __name__ == "__main__":
    main()
