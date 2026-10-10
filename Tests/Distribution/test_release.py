"""Offline checks for release integrity and formula generation failures."""

import contextlib
import hashlib
import io
import json
import os
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import release


class ReleaseIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="aviary-integrity-tests-"))
        self.names = []
        self.digests = {}
        for os_name in ("macos", "linux"):
            for arch in ("arm64", "x86_64"):
                name = f"aviary-1.2.3-{os_name}-{arch}.tar.gz"
                content = f"integrity fixture {os_name} {arch}".encode()
                (self.root / name).write_bytes(content)
                digest = hashlib.sha256(content).hexdigest()
                (self.root / (name + ".sha256")).write_text(f"{digest}  {name}\n")
                self.names.append(name)
                self.digests[name] = digest

    def manifest(self):
        with contextlib.redirect_stdout(io.StringIO()):
            release.collect(self.root, "v1.2.3")
        return self.root / "SHA256SUMS"

    def test_formula_references_verified_platform_assets(self):
        formula = release.render("v1.2.3", self.manifest(), "grahamannett/aviary-swift")
        for name in self.names:
            self.assertIn(
                f'      url "https://github.com/grahamannett/aviary-swift/releases/download/v1.2.3/{name}"\n'
                f'      sha256 "{self.digests[name]}"',
                formula,
            )
        self.assertEqual(formula.count("      sha256 "), 4)
        self.assertNotIn("no_check", formula)
        self.assertIn('libexec.install Dir["*"]', formula)
        self.assertIn('shell_output("#{bin}/aviary --help")', formula)
        self.assertIn(
            'shell_output("#{libexec}/libexec/aviary-selftest --resources-only")',
            formula,
        )
        self.assertTrue(formula.endswith("end\n"))
        self.assertEqual(release.formula_version(formula), "1.2.3")

    def test_custom_base_url_is_normalized(self):
        content = release.render(
            "1.2.3",
            self.manifest(),
            "example/aviary",
            "https://example.test/binaries///",
        )
        self.assertIn('homepage "https://github.com/example/aviary"', content)
        for name in self.names:
            self.assertIn(f'url "https://example.test/binaries/{name}"', content)

    def test_template_resource_is_independent_of_working_directory(self):
        manifest = self.manifest()
        expected = release.render("1.2.3", manifest, "example/aviary")
        outside = self.root / "outside checkout"
        outside.mkdir()
        with contextlib.chdir(outside):
            self.assertEqual(
                release.render("1.2.3", manifest, "example/aviary"), expected
            )

    def test_unknown_template_placeholder_fails(self):
        template = self.root / "unknown-placeholder.rb.in"
        template.write_text(release.TEMPLATE_PATH.read_text() + "${unknown}\n")
        with mock.patch.object(release, "TEMPLATE_PATH", template):
            with self.assertRaisesRegex(KeyError, "unknown"):
                release.render("1.2.3", self.manifest(), "example/aviary")

    @unittest.skipUnless(shutil.which("ruby"), "Ruby is not installed")
    def test_rendered_formula_has_valid_ruby_syntax(self):
        target = self.root / "aviary.rb"
        target.write_text(release.render("1.2.3", self.manifest(), "example/aviary"))
        result = subprocess.run(
            ["ruby", "-c", str(target)], capture_output=True, text=True, timeout=30
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_tampered_archive_does_not_generate_manifest(self):
        (self.root / self.names[0]).write_bytes(b"changed after build")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            self.manifest()
        self.assertFalse((self.root / "SHA256SUMS").exists())

    def test_incomplete_release_does_not_generate_formula(self):
        sums = self.manifest()
        sums.write_text("\n".join(sums.read_text().splitlines()[:3]) + "\n")
        with self.assertRaisesRegex(ValueError, "Missing checksum"):
            release.render("1.2.3", sums, "grahamannett/aviary-swift")

    def test_duplicate_asset_checksum_is_rejected(self):
        sums = self.manifest()
        content = sums.read_text()
        sums.write_text(content + content.splitlines()[0] + "\n")
        with self.assertRaisesRegex(ValueError, "Duplicate checksum"):
            release.render("1.2.3", sums, "grahamannett/aviary-swift")

    def test_formula_interpolation_injection_is_rejected(self):
        for suffix in ("#{bad}", '"', "\n", "\r", "\\"):
            with self.subTest(suffix=suffix):
                with self.assertRaisesRegex(ValueError, "Unsafe formula URL"):
                    release.render(
                        "1.2.3",
                        self.manifest(),
                        "grahamannett/aviary-swift",
                        "https://example.test/" + suffix,
                    )

    def test_invalid_version_and_repository_are_rejected(self):
        checksums = self.manifest()
        with self.assertRaisesRegex(ValueError, "semantic version"):
            release.render('1.2.3"', checksums, "example/aviary")
        with self.assertRaisesRegex(ValueError, "repository owner/name"):
            release.render("1.2.3", checksums, 'example/aviary"')

    def test_formula_requires_exactly_one_literal_version(self):
        for content in (
            "class Aviary < Formula\nend\n",
            '  version "1.2.3"\n  version "1.2.4"\n',
            '  version ENV["VERSION"]\n',
            '  version "1.2.3"\n  version ENV["VERSION"]\n',
        ):
            with self.subTest(content=content):
                with self.assertRaisesRegex(ValueError, "literal version"):
                    release.formula_version(content)

    def test_formula_version_requires_canonical_stable_version(self):
        for version in (
            "v1.2.3",
            "01.2.3",
            "1.02.3",
            "1.2.03",
            "1.2.3-rc.1",
            "1.2",
            "1.2.3٣",
        ):
            with self.subTest(version=version):
                with self.assertRaisesRegex(ValueError, "canonical stable"):
                    release.formula_version(f'  version "{version}"\n')
        self.assertEqual(release.formula_version('  version "0.0.0"\n'), "0.0.0")

    def test_license_comments_survive_generated_and_conditional_preambles(self):
        openssl = "// Copyright 2014-2020 The OpenSSL Project Authors.\n// Apache License terms."
        hrss = "// Copyright (c) 2017, the HRSS authors.\n// Apache License terms."
        block = "/* Copyright another author.\n * Redistribution terms.\n */"
        source = (
            "#define BORINGSSL_PREFIX CCryptoBoringSSL\n"
            "// Generated source. Do not edit.\n\n"
            "#include <assembly.h>\n#if defined(ARM64)\n"
            + openssl
            + "\n#endif\n#if defined(X86_64)\n"
            + hrss
            + "\n#endif\nint preamble;\n"
            + block
            + "\n"
        )
        self.assertEqual(
            release.copyright_bearing_comments(source), {openssl, hrss, block}
        )

    def test_license_line_comment_at_eof_is_preserved(self):
        comment = "// Copyright an author; license terms."
        self.assertEqual(
            release.copyright_bearing_comments("#if ENABLED\n" + comment), {comment}
        )


class ArchiveLayoutTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="aviary-layout-tests-"))
        self.build = self.root / "build"
        self.repository = self.root / "repository"
        self.build.mkdir()
        self.repository.mkdir()
        header = b"\x7fELF\x02\x01" + bytes(12) + struct.pack("<H", 62)
        for executable in ("aviary", "AviarySelfTest"):
            (self.build / executable).write_bytes(header + b"executable fixture")
        bundle = self.build / "aviary_XClient.resources"
        bundle.mkdir()
        (bundle / "query-ids.json").write_text('{"Query": "fixture"}\n')
        (self.repository / "THIRD_PARTY_NOTICES.md").write_text("Third-party notices\n")
        (self.repository / "LICENSE").write_text("Aviary license\n")
        bird = self.repository / "licenses"
        bird.mkdir()
        (bird / "Bird-LICENSE.txt").write_text("Bird license\n")
        checkouts = self.repository / ".build/checkouts"
        for dependency in ("swift-argument-parser", "swift-crypto", "swift-asn1"):
            checkout = checkouts / dependency
            checkout.mkdir(parents=True)
            (checkout / "LICENSE.txt").write_text(f"{dependency} license\n")
        (checkouts / "swift-crypto/NOTICE.txt").write_text("Swift crypto notice\n")
        boring_ssl = checkouts / "swift-crypto/Sources/CCryptoBoringSSL"
        boring_ssl.mkdir(parents=True)
        (boring_ssl / "source.c").write_text(
            "#define GENERATED\n/* Copyright a fixture author.\n * License terms.\n */\n"
        )

    def package(self, directory):
        options = release.PackageOptions(
            build_dir=self.build,
            output_dir=directory,
            version="v1.2.3",
            platform="linux",
            arch="x86_64",
            repository_dir=self.repository,
        )
        with (
            mock.patch.object(release, "bundle_linux_dependencies", return_value=[]),
            mock.patch.dict(os.environ, {"SOURCE_DATE_EPOCH": "123456"}),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            release.package(options)
        return directory / "aviary-1.2.3-linux-x86_64.tar.gz"

    def test_archive_layout_permissions_metadata_and_licenses(self):
        archive = self.package(self.root / "output")
        with tarfile.open(archive, "r:gz") as tar:
            members = {member.name: member for member in tar.getmembers()}
            expected = {
                "bin/aviary",
                "libexec/aviary-selftest",
                "bin/aviary_XClient.resources/query-ids.json",
                "share/doc/aviary/LICENSE",
                "share/doc/aviary/THIRD_PARTY_NOTICES.md",
                "share/doc/aviary/dependencies/Bird-LICENSE.txt",
                "share/doc/aviary/dependencies/swift-argument-parser-LICENSE.txt",
                "share/doc/aviary/dependencies/swift-crypto-LICENSE.txt",
                "share/doc/aviary/dependencies/swift-asn1-LICENSE.txt",
                "share/doc/aviary/dependencies/swift-crypto-NOTICE.txt",
                "share/doc/aviary/dependencies/BoringSSL-NOTICES.txt",
                "share/doc/aviary/release.json",
            }
            self.assertTrue(expected <= members.keys())
            self.assertEqual(members["bin/aviary"].mode, 0o755)
            self.assertEqual(members["libexec/aviary-selftest"].mode, 0o755)
            for member in members.values():
                self.assertEqual((member.uid, member.gid, member.mtime), (0, 0, 123456))
                self.assertEqual((member.uname, member.gname), ("root", "root"))
            metadata = json.load(tar.extractfile("share/doc/aviary/release.json"))
            self.assertEqual(
                metadata,
                {
                    "version": "1.2.3",
                    "platform": "linux",
                    "architecture": "x86_64",
                    "libraries": [],
                },
            )
            notices = (
                tar.extractfile("share/doc/aviary/dependencies/BoringSSL-NOTICES.txt")
                .read()
                .decode()
            )
            self.assertIn("Copyright a fixture author.", notices)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.assertEqual(
            archive.with_suffix(".gz.sha256").read_text(), f"{digest}  {archive.name}\n"
        )

    def test_archive_bytes_ignore_staging_names_and_input_timestamps(self):
        first = self.package(self.root / "first")
        for source in self.build.rglob("*"):
            os.utime(source, (987654321, 987654321))
        second = self.package(self.root / "second")
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_existing_archive_is_not_overwritten(self):
        output = self.root / "output"
        archive = self.package(output)
        before = archive.read_bytes()
        with self.assertRaisesRegex(FileExistsError, "Refusing to overwrite"):
            self.package(output)
        self.assertEqual(archive.read_bytes(), before)

    def test_missing_resource_bundle_fails_before_archive_creation(self):
        (self.build / "aviary_XClient.resources").rename(
            self.build / "hidden-resources"
        )
        output = self.root / "output"
        with self.assertRaisesRegex(
            RuntimeError, "Expected one XClient resource bundle"
        ):
            self.package(output)
        self.assertFalse((output / "aviary-1.2.3-linux-x86_64.tar.gz").exists())

    def test_linux_executable_architecture_is_checked(self):
        with self.assertRaisesRegex(RuntimeError, "does not match arm64"):
            release.validate_executable(self.build / "aviary", "linux", "arm64")

    def test_truncated_linux_header_has_clear_error(self):
        executable = self.build / "aviary"
        executable.write_bytes(b"\x7fELF\x02\x01")
        with self.assertRaisesRegex(RuntimeError, "64-bit little-endian"):
            release.validate_executable(executable, "linux", "x86_64")


if __name__ == "__main__":
    unittest.main()
