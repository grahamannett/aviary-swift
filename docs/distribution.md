# Distribution

Release packages target macOS 13+ and Ubuntu 22.04/24.04 or Debian 12, on arm64 and x86_64. Linux archives include the Swift runtime and other required shared libraries; users do not need a Swift compiler. Install system CA certificates for HTTPS requests. Browser credential extraction still requires a local browser profile and, for Chrome on Linux, an unlocked desktop keyring or a profile using basic password storage. Explicit `--auth-token` and `--ct0` credentials work on headless systems. Windows, Alpine Linux, and automatic Snap/Flatpak profile discovery are outside the initial support matrix.

## Install and replace Bird

After the first binary release and tap update, install with either:

```sh
brew install grahamannett/tap/aviary
mise use -g github:grahamannett/aviary-swift@latest
```

Homebrew downloads the archive for the host OS and architecture, installs the complete archive into its private `libexec` directory, and exposes `aviary` through a symlink. mise's GitHub backend selects the platform archive and exposes its `bin` directory. Keep the complete installed tree: copying only the executable loses the resource bundle and Linux runtime libraries.

For Homebrew, an optional `bird` command can point to the installed Aviary executable:

```sh
mkdir -p "$HOME/.local/bin"
ln -s "$(brew --prefix aviary)/bin/aviary" "$HOME/.local/bin/bird"
```

Ensure `~/.local/bin` is on your shell's `PATH`. If a `bird` file already exists there, inspect it before replacing it. Use `trash` to remove a stale file that you have identified.

For mise, use an exact executable rename in your global mise configuration instead of the default tool entry:

```toml
[tools."github:grahamannett/aviary-swift"]
version = "latest"
rename_exe = { aviary = "bird" }
```

Run `mise install` after saving the configuration. If Aviary was already installed at that version, run `mise install --force github:grahamannett/aviary-swift` to apply the rename during extraction. Renaming exposes `bird` in place of `aviary` for that mise installation. Both invocation names load the same packaged resources and accept existing Bird config files; help identifies the application as Aviary.

Remove the old Bird package using whichever manager installed it, such as `mise uninstall bird` or `npm uninstall -g @steipete/bird`. Then run `mise reshim` if you use mise shims. Check `type -a bird`, `bird --version`, and `bird query-ids --json` to confirm command resolution and offline resource loading. Inspect existing shell aliases/functions if the old command still wins.

Upgrade with `brew upgrade aviary` or `mise upgrade github:grahamannett/aviary-swift`. Uninstall with `brew uninstall aviary` or `mise uninstall --all github:grahamannett/aviary-swift`; remove its mise config entry to stop reinstalling it. Use `trash "$HOME/.local/bin/bird"` to remove the optional Homebrew symlink. User configs and caches remain in their existing locations.

## Build a release archive

Build with Swift 6.1 or later; CI pins Swift 6.1.3. A release tag must match `aviary --version`. Linux builds use Ubuntu 22.04 to establish the glibc compatibility baseline, and require SQLite development headers, pkg-config, and patchelf. macOS builds target macOS 13.

```sh
swift test
swift build -c release --product aviary
swift build -c release --product AviarySelfTest
uv run --no-project --python 3.12 python scripts/package-release.py \
  --build-dir "$(swift build -c release --show-bin-path)" \
  --output-dir dist --version 0.8.0 --platform macos --arch arm64
uv run --no-project --python 3.12 python scripts/smoke-release.py \
  dist/aviary-0.8.0-macos-arm64.tar.gz
```

For Linux, set `--platform linux`, choose the native architecture, and supply `--swift-runtime-license /path/to/swift-LICENSE.txt`. Use the license from the matching Swift release. Packaging never overwrites an existing archive; use a new output directory for another build. Temporary staging and validation directories are retained for inspection and may be removed with `trash` afterward.

Each archive contains `bin/aviary`, the adjacent SwiftPM XClient resource bundle, `libexec/aviary-selftest`, and notices under `share/doc/aviary`. Linux also includes `lib/` with the complete non-glibc dynamic dependency closure. Packaging sets relative runtime search paths on the executable, diagnostic helper, and every bundled library. The system loader and glibc remain supplied by the host OS. Swift package licenses, notices, vendored BoringSSL license headers, and Ubuntu library copyright files accompany the binaries.

The four asset names are `aviary-VERSION-macos-arm64.tar.gz`, `aviary-VERSION-macos-x86_64.tar.gz`, `aviary-VERSION-linux-arm64.tar.gz`, and `aviary-VERSION-linux-x86_64.tar.gz`. `scripts/collect-checksums.py dist VERSION` verifies the individual hashes and produces `SHA256SUMS` only when all four archives exist.

## Release workflow and Homebrew tap

Pushing a stable `vMAJOR.MINOR.PATCH` tag runs `.github/workflows/release.yml`. The first job rejects prerelease and invalid tags before builds or publication. It tests and packages all four platforms, validates Linux runtime-only containers on Ubuntu 22.04/24.04 and Debian 12, and uploads the artifacts and checksums to a draft GitHub release. The installer jobs test Homebrew and mise on both architectures before the release becomes public. Failed validation leaves the release as a draft. Manual packaging scripts can build prerelease archives, but this workflow publishes stable releases and updates the stable tap only.

Draft browser download URLs are not public. Installer validation therefore serves the exact candidate artifacts from a local GitHub-compatible mirror, verifies mise's GitHub backend with platform autodetection, and uses a temporary Homebrew tap with the same archive hashes. An initial `0.0.0` metadata fixture points at the same artifact bytes to exercise upgrade mechanics without requiring a previous public release. The validation script isolates mise config/data and refuses to change an existing Homebrew Aviary installation. It checks install, upgrade, resource diagnostics, optional `bird` invocation, and uninstall without contacting X or reading personal browser cookies.

The public `grahamannett/homebrew-tap` repository contains the generated `Formula/aviary.rb` and a short README. Before the first release it can be seeded with the macOS source bootstrap:

```sh
bash scripts/bootstrap-homebrew-tap.sh --head /tmp/homebrew-tap
brew install --HEAD grahamannett/tap/aviary
```

Source bootstrap installation needs Xcode 16.3 or later. The production binary formula is generated only from complete, real release checksums:

```sh
bash scripts/bootstrap-homebrew-tap.sh 0.8.0 dist/SHA256SUMS /tmp/homebrew-tap
```

The bootstrap script prepares files without creating, committing, or pushing a repository. Configure the Aviary repository's `HOMEBREW_TAP_TOKEN` Actions secret with a fine-grained token granting contents write access to `grahamannett/homebrew-tap` to enable automatic updates. The default GitHub Actions token cannot write to another repository. Without the secret, the release still publishes, the workflow reports a warning, and the generated `aviary.rb` attached to the release can be committed to the tap manually.

Do not edit archive checksums by hand or publish formula URLs before their release exists. A failed release workflow can be rerun while its release remains a draft; it refuses to replace an already public release.

## Validation limits

Packaging smoke checks run outside the checkout, after relocation into a path containing spaces, and verify bundled query IDs and feature switches. They exercise symlinked and renamed executables, and require the diagnostic helper to fail when the installed bundle is hidden. Linux containers run with no Swift toolchain and no network access. macOS CI runners are newer than macOS 13, so a macOS 13 machine still needs a compatibility smoke check before declaring that OS version independently verified. Linux desktop authentication needs a read-only manual account check with conventional Chrome and Firefox profiles; the offline suite covers cookie fixtures, decryption, fallback, timeout and missing-keyring behavior.
