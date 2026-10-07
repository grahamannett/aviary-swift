# Distribution

Release packages target macOS 13+ and Ubuntu 22.04/24.04 or Debian 12, on arm64 and x86_64. Linux archives include the Swift runtime and required shared libraries. Users do not need Swift or Python to run Aviary. Linux needs system CA certificates for HTTPS, and Chrome cookie extraction needs an unlocked desktop keyring or basic password storage. Firefox and explicit `--auth-token`/`--ct0` credentials also work on headless systems. Windows, Alpine, and automatic Snap/Flatpak profile discovery are outside the initial support matrix.

## Install

```sh
brew install grahamannett/tap/aviary
mise use -g github:grahamannett/aviary-swift@latest
```

Both managers install the complete archive. Copying only the executable loses its resource bundle and Linux runtime libraries. Upgrade with `brew upgrade aviary` or `mise upgrade github:grahamannett/aviary-swift`. Uninstall with `brew uninstall aviary` or `mise uninstall --all github:grahamannett/aviary-swift`; remove its mise config entry to stop reinstalling it.

## Optional Bird command

For Homebrew, put a symlink on your shell's PATH:

```sh
mkdir -p "$HOME/.local/bin"
ln -s "$(brew --prefix aviary)/bin/aviary" "$HOME/.local/bin/bird"
```

If that path already contains a file, inspect it before replacing it. Use `trash` to remove an identified stale file. For mise, use an exact executable rename in your global configuration:

```toml
[tools."github:grahamannett/aviary-swift"]
version = "latest"
rename_exe = { aviary = "bird" }
```

Run `mise install`; if that version is already installed, use `mise install --force github:grahamannett/aviary-swift` to apply the rename. Remove the old Bird package with its original manager and run `mise reshim` if you use shims. Check `type -a bird`, `bird --version`, and `bird query-ids --json`. Both names load Aviary's resources and accept existing Bird config files. Aviary keeps separate caches. To remove the optional Homebrew symlink, use `trash "$HOME/.local/bin/bird"`.

## CI and releases

Normal CI runs the offline Swift tests on macOS ARM64 and Linux x86_64, plus the release-tooling unit tests. macOS uses the runner's preinstalled Xcode 16.3. Linux uses the official `swift:6.1.3-jammy` container, which already contains Swift. Both cache `.build`; neither downloads a separate Swift toolchain or creates release archives on every PR.

A stable `vMAJOR.MINOR.PATCH` tag runs the release workflow. It tests and builds all four native platforms, packages each archive, and checks relocation, bundled resources, symlinks, renamed executables, and missing-resource failures. Linux archives also run in Ubuntu 22.04/24.04 and Debian 12 containers with no network or Swift installation. The final job verifies all four checksums, generates the Homebrew formula, uploads a complete draft, and publishes it. Public releases are never overwritten.

The Homebrew formula lives in [grahamannett/homebrew-tap](https://github.com/grahamannett/homebrew-tap). Set `HOMEBREW_TAP_TOKEN` in Aviary's Actions secrets to a fine-grained token with contents write permission for that repository to enable automatic formula updates. Without it, commit the release's attached `aviary.rb` to the tap manually. No separate tap bootstrap or local installer is needed.

## Release tooling

`scripts/release.py` has three commands: `package` creates one platform archive; `check` validates an extracted archive offline; `prepare` verifies all four archives and writes `SHA256SUMS` and `aviary.rb`. It uses only Python's standard library, runs through uv, and selects Python 3.14. The other script, `generate-bird-fixtures.mjs`, maintains the Bird compatibility fixtures.

```sh
swift build -c release
uv run --no-project --python 3.14 python scripts/release.py package \
  --build-dir "$(swift build -c release --show-bin-path)" \
  --output-dir dist --version 0.1.0 --platform macos --arch arm64
uv run --no-project --python 3.14 python scripts/release.py check \
  dist/aviary-0.1.0-macos-arm64.tar.gz
# After collecting all four platform archives and their .sha256 files:
uv run --no-project --python 3.14 python scripts/release.py prepare dist 0.1.0
```

Linux packaging needs `libsqlite3-dev` and `patchelf`, and takes `--swift-runtime-license /usr/share/swift/LICENSE.txt` from the official Swift image. Archives include the executable, resource bundle, diagnostic helper, and dependency notices. Linux packaging bundles the non-glibc dependency closure and sets relative runtime search paths. The system loader and glibc stay supplied by the host. Packaging refuses to overwrite an existing archive; use a new output directory. Temporary validation directories stay available for inspection and can be removed with `trash`.

Run the tooling unit tests with `mise run test-release-tooling`. Check Homebrew and mise installation using their public release commands.

## Validation limits

macOS CI runners are newer than macOS 13, so that version still needs a hardware smoke check. Linux desktop authentication needs a read-only manual check with conventional Chrome and Firefox profiles; the offline suite covers cookie fixtures, decryption, fallback, timeout, and missing-keyring behavior.
