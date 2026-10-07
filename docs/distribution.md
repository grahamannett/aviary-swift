# Distribution

Release packages target macOS 13+ and Ubuntu 22.04/24.04 or Debian 12, on arm64 and x86_64. Linux archives include the Swift runtime and required shared libraries. Users do not need Swift or Python to run Aviary. Linux needs system CA certificates for HTTPS, and Chrome cookie extraction needs an unlocked desktop keyring or basic password storage. Firefox and explicit `--auth-token`/`--ct0` credentials also work on headless systems. Windows, Alpine, and automatic Snap/Flatpak profile discovery are outside the initial support matrix.

## Install

```sh
brew install grahamannett/tap/aviary
mise use -g github:grahamannett/aviary-swift@0.1.1
```

Both managers install the complete archive. Copying only the executable loses its resource bundle and Linux runtime libraries. The explicit mise version works immediately; current mise defaults exclude releases less than 24 hours old when resolving `@latest`. Upgrade with `brew upgrade aviary` or `mise upgrade --bump github:grahamannett/aviary-swift`. Uninstall with `brew uninstall aviary` or `mise uninstall --all github:grahamannett/aviary-swift`; remove its mise config entry to stop reinstalling it.

## Optional Bird command

With mise 2026.10.3 or newer, use a command wrapper in your global mise configuration. This keeps both `aviary` and `bird` available and follows the selected Aviary version:

```toml
[tools]
"github:grahamannett/aviary-swift" = "0.1.1"

[wrappers]
bird = "aviary"
```

Run `mise install github:grahamannett/aviary-swift` and `mise reshim`. Interactive shells can use `mise activate`; scripts and agents need mise's `command-wrappers/bin` and `shims` directories on PATH before other Bird installations. With the default mise data directory, these are `~/.local/share/mise/command-wrappers/bin` and `~/.local/share/mise/shims`. Check `type -a bird`, `bird --version`, `aviary --version`, and `bird query-ids --json`. Use generic `bird` in skills and scripts so they follow this routing.

To retain original Bird as an explicit backup, point another wrapper at its existing executable. For example, if original Bird is installed by Homebrew on Apple Silicon:

```toml
[wrappers]
bird = "aviary"
bird-original = "/opt/homebrew/bin/bird"
```

Remove the original Bird tool from mise's active configuration if present, while retaining its installation, and run `mise reshim`. Verify `bird-original --version`. Backup use is explicit; do not automatically retry failed commands through original Bird. Aviary accepts existing Bird config files and keeps separate caches. To restore original Bird as the default, change the `bird` wrapper target to its absolute executable path and run `mise reshim`.

For a Homebrew Aviary installation without mise, an executable symlink in `~/.local/bin` also works:

```sh
mkdir -p "$HOME/.local/bin"
ln -s "$(brew --prefix aviary)/bin/aviary" "$HOME/.local/bin/bird"
```

Inspect an existing destination before replacing it; use `trash` for an identified stale file or to remove the optional symlink.

## Shell completions

Aviary already generates Bash, Zsh, and Fish completions from its command declarations. Generate the file once after installation and regenerate it after upgrading; shell startup can load that file without invoking Aviary each time. Completions cover commands and options and do not need authentication.

### Zsh

```sh
mkdir -p "$HOME/.zsh/completions"
aviary --generate-completion-script zsh > "$HOME/.zsh/completions/_aviary"
```

Add the directory before your existing `compinit` call in `~/.zshrc`. If you do not already initialize completions, use:

```sh
fpath=("$HOME/.zsh/completions" $fpath)
autoload -Uz compinit
compinit
```

To complete the optional `bird` wrapper too, add `compdef _aviary bird` after `compinit`.

### Fish

Fish automatically loads completion files from its completions directory. With the default configuration directory:

```sh
mkdir -p "$HOME/.config/fish/completions"
aviary --generate-completion-script fish > "$HOME/.config/fish/completions/aviary.fish"
```

For the optional `bird` wrapper, create `~/.config/fish/completions/bird.fish` containing `complete -c bird -w aviary`. If your Fish configuration directory differs, use its `completions` subdirectory instead.

### Bash

```sh
mkdir -p "$HOME/.bash_completions"
aviary --generate-completion-script bash > "$HOME/.bash_completions/aviary.bash"
```

Source the file from your interactive shell startup file, typically `~/.bashrc` or `~/.bash_profile`:

```sh
source "$HOME/.bash_completions/aviary.bash"
```

For the optional `bird` wrapper, add `complete -o filenames -F _aviary bird` after sourcing the file. Open a new shell after configuring completions.

## Local development

`mise.toml` pins Swift 6.3.3 and uv 0.12.23. Run `mise install swift uv` to install them, or let `mise run` install missing tools automatically. macOS still needs Xcode or Command Line Tools for its SDK. Build tasks always invoke SwiftPM so it can check the selected compiler and SDK as well as source changes; SwiftPM handles incremental builds.

The project configuration leaves released `aviary` and `bird` commands on PATH. Run `mise run aviary -- --help` to build and execute the local release binary, or `mise run run -- --help` for the debug binary. To build without running, use `mise run build` or `mise run build-debug`; the executables and their resources stay in `.build`.

## CI and releases

Normal CI runs the offline Swift tests on macOS ARM64 and Linux x86_64, plus the release-tooling unit tests. macOS uses the runner's preinstalled Xcode 16.3. Linux uses the official `swift:6.1.3-jammy` container, which already contains Swift. This older Swift baseline checks compatibility and builds releases; local mise tasks use Swift 6.3.3. Both cache `.build`; neither downloads a separate Swift toolchain or creates release archives on every PR. CI and release workflows pin uv to 0.12.23 and select Python 3.14.8.

A stable `vMAJOR.MINOR.PATCH` tag runs the release workflow. It tests and builds all four native platforms, packages each archive, and checks relocation, bundled resources, symlinks, renamed executables, and missing-resource failures. Linux archives also run in Ubuntu 22.04/24.04 and Debian 12 containers with no network or Swift installation. The final job verifies all four checksums, generates the Homebrew formula, uploads a complete draft, and publishes it. Public releases are never overwritten.

The Homebrew formula lives in [grahamannett/homebrew-tap](https://github.com/grahamannett/homebrew-tap). Set `HOMEBREW_TAP_TOKEN` in Aviary's Actions secrets to a fine-grained token with contents write permission for that repository to enable automatic formula updates. Without it, commit the release's attached `aviary.rb` to the tap manually. No separate tap bootstrap or local installer is needed.

## Release tooling

`scripts/release.py` has three commands: `package` creates one platform archive; `check` validates an extracted archive offline; `prepare` verifies all four archives and writes `SHA256SUMS` and `aviary.rb`. It uses only Python's standard library, runs through uv, and selects Python 3.14.8. uv finds or downloads that interpreter, so mise does not install a separate Python toolchain. The other script, `generate-bird-fixtures.mjs`, maintains the Bird compatibility fixtures.

```sh
mise run build
mise exec -- uv run --no-project --python 3.14.8 python scripts/release.py package \
  --build-dir "$(mise exec -- swift build -c release --show-bin-path)" \
  --output-dir dist --version 0.1.1 --platform macos --arch arm64
mise exec -- uv run --no-project --python 3.14.8 python scripts/release.py check \
  dist/aviary-0.1.1-macos-arm64.tar.gz
# After collecting all four platform archives and their .sha256 files:
mise exec -- uv run --no-project --python 3.14.8 python scripts/release.py prepare dist 0.1.1
```

Linux packaging needs `libsqlite3-dev` and `patchelf`, and takes `--swift-runtime-license /usr/share/swift/LICENSE.txt` from the official Swift image. Archives include the executable, resource bundle, diagnostic helper, and dependency notices. Linux packaging bundles the non-glibc dependency closure and sets relative runtime search paths. The system loader and glibc stay supplied by the host. Packaging refuses to overwrite an existing archive; use a new output directory. Temporary validation directories stay available for inspection and can be removed with `trash`.

Run the tooling unit tests with `mise run test-release-tooling`.

## Installer checks

The `check:brew_*` and `check:mise_*` tasks use a shared environment in `mise.test.toml`, so each operation has a short, stable command to approve. HOME, config, data, and caches use `/tmp/aviary-install-test`; authentication and cache overrides are cleared.

```sh
mise run check:mise_install
mise run check:mise_bird
mise run check:mise_uninstall

mise run check:brew_install
mise run check:brew_test
mise run check:brew_uninstall
mise run check:brew_untap
```

The mise tasks affect only the temporary installation. Homebrew uses its normal system prefix. Set `AVIARY_INSTALL_TEST_VERSION` or `AVIARY_INSTALL_TEST_ROOT` to select a different release or temporary directory; the root must be an absolute path.

## Validation limits

macOS CI runners are newer than macOS 13, so that version still needs a hardware smoke check. Linux desktop authentication needs a read-only manual check with conventional Chrome and Firefox profiles; the offline suite covers cookie fixtures, decryption, fallback, timeout, and missing-keyring behavior.
