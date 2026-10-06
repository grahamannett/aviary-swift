#!/usr/bin/env -S uv run --no-project python
"""Validate installers against an isolated local mirror of real release artifacts.

The previous-version fixture uses the same bytes under version 0.0.0, solely to
exercise upgrade mechanics before Aviary has a previous public release.
"""

import argparse
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import urllib.parse


def load_renderer():
    spec = importlib.util.spec_from_file_location("render_formula", Path(__file__).with_name("render-homebrew-formula.py"))
    renderer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(renderer)
    return renderer.render


def validate(args):
    version = args.version.removeprefix("v")
    task_root = Path(tempfile.mkdtemp(prefix="aviary-installers-"))
    home = task_root / "home"
    home.mkdir()
    work = task_root / "work"
    work.mkdir()
    files = {p.name: p.resolve() for p in args.archives_dir.glob("*.tar.gz")}
    files["SHA256SUMS"] = (args.archives_dir / "SHA256SUMS").resolve()
    assets = []
    for index, (name, path) in enumerate(sorted(files.items())):
        if not path.is_file():
            raise FileNotFoundError(path)
        assets.append({"id": index + 1, "name": name, "size": path.stat().st_size, "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest(), "content_type": "application/octet-stream", "state": "uploaded"})
    release_version = "0.0.0"

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def do_GET(self):
            path = urllib.parse.urlsplit(self.path).path
            if path.startswith("/assets/"):
                name = urllib.parse.unquote(path.removeprefix("/assets/"))
                actual_name = name.replace("aviary-0.0.0-", f"aviary-{version}-", 1)
                if actual_name not in files:
                    self.send_error(404)
                    return
                data = files[actual_name].read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            release_assets = []
            for asset in assets:
                entry = dict(asset)
                entry["name"] = entry["name"].replace(f"aviary-{version}-", f"aviary-{release_version}-", 1)
                url = f"{base}/assets/{entry['name']}"
                entry.update(url=url, browser_download_url=url)
                release_assets.append(entry)
            release = {"id": 1, "tag_name": f"v{release_version}", "name": f"Aviary {release_version}", "draft": False, "prerelease": False, "created_at": "2026-01-01T00:00:00Z", "published_at": "2026-01-01T00:00:00Z", "assets": release_assets, "html_url": f"{base}/releases/v{release_version}", "body": "Installer fixture"}
            endpoint = f"/repos/{args.repository}/releases"
            if path == endpoint:
                payload = [release]
            elif path in {f"{endpoint}/latest", f"{endpoint}/tags/v{release_version}", f"{endpoint}/tags/{release_version}"}:
                payload = release
            else:
                self.send_error(404)
                return
            data = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    base = f"http://127.0.0.1:{server.server_port}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ)
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"), AVIARY_SKIP_QUERY_ID_REFRESH="1", MISE_CONFIG_DIR=str(home / "mise-config"), MISE_DATA_DIR=str(home / "mise-data"), MISE_CACHE_DIR=str(home / "mise-cache"), MISE_STATE_DIR=str(home / "mise-state"), MISE_YES="1", MISE_ENV_FILE="", MISE_PARANOID="0", HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_NO_INSTALL_CLEANUP="1")
    for key in ("AUTH_TOKEN", "CT0", "LD_LIBRARY_PATH", "BIRD_QUERY_IDS_CACHE", "AVIARY_QUERY_IDS_CACHE", "BIRD_FEATURES_CACHE", "AVIARY_FEATURES_CACHE"):
        env.pop(key, None)

    def run(*command):
        print("+ " + " ".join(str(c) for c in command), flush=True)
        result = subprocess.run([str(c) for c in command], cwd=work, env=env, stderr=subprocess.STDOUT, stdout=subprocess.PIPE, text=True)
        if result.returncode:
            print(result.stdout, flush=True)
            raise RuntimeError(f"Command exited {result.returncode}: {command}")
        return result.stdout

    try:
        if args.installer == "mise":
            if not shutil.which("mise"):
                raise RuntimeError("Install mise before running installer validation")
            tool = f"github:{args.repository}[api_url={base}]"
            print(run("mise", "use", "-g", f"{tool}@latest"))
            print(run("mise", "exec", "--", "aviary", "query-ids", "--json"))
            release_version = version
            print(run("mise", "cache", "clear"))
            print(run("mise", "upgrade", tool))
            print(run("mise", "exec", "--", "aviary", "query-ids", "--json"))
            location = Path(run("mise", "where", f"{tool}@{version}").strip())
            print(run(location / "libexec/aviary-selftest", "--resources-only"))
            # Exact-name map is required because the repository is aviary-swift.
            # A separate isolated install ensures rename is applied during extraction.
            env["MISE_DATA_DIR"] = str(home / "mise-bird-data")
            env["MISE_CACHE_DIR"] = str(home / "mise-bird-cache")
            rename_config = work / "mise.toml"
            rename_config.write_text(f'[tools."github:{args.repository}"]\nversion = "{version}"\napi_url = "{base}"\nrename_exe = {{ aviary = "bird" }}\n')
            print(run("mise", "trust", rename_config))
            print(run("mise", "install"))
            print(run("mise", "exec", "--", "bird", "query-ids", "--json"))
            print(run("mise", "uninstall", f"github:{args.repository}"))
            env["MISE_DATA_DIR"] = str(home / "mise-data")
            env["MISE_CACHE_DIR"] = str(home / "mise-cache")
            print(run("mise", "uninstall", "--all", tool))
            if location.exists():
                raise RuntimeError(f"mise uninstall left installed version at {location}")
        else:
            if not shutil.which("brew"):
                raise RuntimeError("Install Homebrew before running installer validation")
            existing = subprocess.run(["brew", "list", "--versions", "aviary"], cwd=work, env=env, capture_output=True, text=True)
            if existing.stdout.strip():
                raise RuntimeError("Installer validation refuses to modify an existing Aviary installation")
            tap = "aviary-validation/release"
            print(run("brew", "tap-new", tap, "--no-git"))
            tap_dir = Path(run("brew", "--repository", tap).strip())
            render = load_renderer()
            checksums = args.archives_dir / "SHA256SUMS"
            previous_checksums = task_root / "SHA256SUMS-previous"
            previous_checksums.write_text(checksums.read_text().replace(f"aviary-{version}-", "aviary-0.0.0-"))
            formula = tap_dir / "Formula/aviary.rb"
            formula.write_text(render("0.0.0", previous_checksums, args.repository, f"{base}/assets"))
            print(run("brew", "install", f"{tap}/aviary"))
            print(run("brew", "test", f"{tap}/aviary"))
            formula.write_text(render(version, checksums, args.repository, f"{base}/assets"))
            print(run("brew", "upgrade", f"{tap}/aviary"))
            print(run("brew", "test", f"{tap}/aviary"))
            prefix = Path(run("brew", "--prefix", "aviary").strip())
            bird = task_root / "bird"
            bird.symlink_to(prefix / "bin/aviary")
            print(run(bird, "query-ids", "--json"))
            print(run("brew", "uninstall", f"{tap}/aviary"))
            print(run("brew", "untap", tap))
    finally:
        server.shutdown()
        server.server_close()
    print(f"{args.installer} install, upgrade, resource diagnostics, bird invocation and uninstall passed")
    print(f"Installer artifacts retained at {task_root}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installer", choices=["mise", "homebrew"], required=True)
    parser.add_argument("--archives-dir", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", default="grahamannett/aviary-swift")
    validate(parser.parse_args())
