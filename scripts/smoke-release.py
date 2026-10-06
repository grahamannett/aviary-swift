#!/usr/bin/env -S uv run --no-project --python 3.14 python
"""Exercise a release after relocation, with isolated credentials and no X calls."""

import argparse
import json
import os
import subprocess
import tarfile
import tempfile
from pathlib import Path


def smoke(archive):
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
    assert "whoami" in run(binary, "--help")
    run(helper, "--resources-only")
    ids = json.loads(run(binary, "query-ids", "--json"))
    if not ids:
        raise RuntimeError("query-ids produced empty JSON")
    symlink_dir = root / "links"
    symlink_dir.mkdir()
    bird = symlink_dir / "bird"
    bird.symlink_to(binary)
    assert json.loads(run(bird, "query-ids", "--json")) == ids
    renamed = package / "bin/bird"
    binary.rename(renamed)
    assert json.loads(run(renamed, "query-ids", "--json")) == ids
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
    run(helper, "--resources-only", success=False)
    hidden.rename(bundles[0])
    run(helper, "--resources-only")
    print(
        f"Release relocation, resources, missing-resource failure, symlink and rename checks passed: {archive}"
    )
    print(f"Smoke artifacts retained at {root}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    smoke(parser.parse_args().archive.resolve())
