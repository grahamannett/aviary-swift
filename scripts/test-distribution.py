#!/usr/bin/env -S uv run --no-project --python 3.14 python
"""Offline checks for release integrity and formula generation failures."""

import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest


def module(filename):
    spec = importlib.util.spec_from_file_location(filename.replace("-", "_"), Path(__file__).with_name(filename + ".py"))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


render = module("render-homebrew-formula").render
collect = module("collect-checksums").collect
copyright_comments = module("package-release").copyright_bearing_comments


class ReleaseIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="aviary-integrity-tests-"))
        self.names = []
        for os_name in ("macos", "linux"):
            for arch in ("arm64", "x86_64"):
                name = f"aviary-1.2.3-{os_name}-{arch}.tar.gz"
                content = f"integrity fixture {os_name} {arch}".encode()
                (self.root / name).write_bytes(content)
                (self.root / (name + ".sha256")).write_text(f"{hashlib.sha256(content).hexdigest()}  {name}\n")
                self.names.append(name)

    def manifest(self):
        with contextlib.redirect_stdout(io.StringIO()):
            collect(self.root, "v1.2.3")
        return self.root / "SHA256SUMS"

    def test_formula_references_verified_platform_assets(self):
        formula = render("v1.2.3", self.manifest(), "grahamannett/aviary-swift")
        for name in self.names:
            self.assertIn(f"https://github.com/grahamannett/aviary-swift/releases/download/v1.2.3/{name}", formula)
        self.assertEqual(formula.count("      sha256 "), 4)
        self.assertNotIn("no_check", formula)
        self.assertIn('libexec.install Dir["*"]', formula)
        self.assertIn("/libexec/aviary-selftest --resources-only", formula)

    def test_tampered_archive_does_not_generate_manifest(self):
        (self.root / self.names[0]).write_bytes(b"changed after build")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            self.manifest()
        self.assertFalse((self.root / "SHA256SUMS").exists())

    def test_incomplete_release_does_not_generate_formula(self):
        sums = self.manifest()
        sums.write_text("\n".join(sums.read_text().splitlines()[:3]) + "\n")
        with self.assertRaisesRegex(ValueError, "Missing checksum"):
            render("1.2.3", sums, "grahamannett/aviary-swift")

    def test_duplicate_asset_checksum_is_rejected(self):
        sums = self.manifest()
        content = sums.read_text()
        sums.write_text(content + content.splitlines()[0] + "\n")
        with self.assertRaisesRegex(ValueError, "Duplicate checksum"):
            render("1.2.3", sums, "grahamannett/aviary-swift")

    def test_formula_interpolation_injection_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Unsafe formula URL"):
            render("1.2.3", self.manifest(), "grahamannett/aviary-swift", "https://example.test/#{bad}")

    def test_license_comments_survive_generated_and_conditional_preambles(self):
        openssl = "// Copyright 2014-2020 The OpenSSL Project Authors.\n// Apache License terms."
        hrss = "// Copyright (c) 2017, the HRSS authors.\n// Apache License terms."
        block = "/* Copyright another author.\n * Redistribution terms.\n */"
        source = (
            "#define BORINGSSL_PREFIX CCryptoBoringSSL\n"
            "// Generated source. Do not edit.\n\n"
            "#include <assembly.h>\n#if defined(ARM64)\n"
            + openssl + "\n#endif\n#if defined(X86_64)\n"
            + hrss + "\n#endif\nint preamble;\n" + block + "\n"
        )
        self.assertEqual(copyright_comments(source), {openssl, hrss, block})

    def test_license_line_comment_at_eof_is_preserved(self):
        comment = "// Copyright an author; license terms."
        self.assertEqual(copyright_comments("#if ENABLED\n" + comment), {comment})


if __name__ == "__main__":
    unittest.main()
