# Distribution

Release packages target macOS 13+ and Ubuntu 24.04, on arm64 and x86_64. Linux archives include the Swift runtime and required shared libraries; the host supplies glibc. Installing through mise uses the same binaries and therefore has the same Linux compatibility requirements. Users do not need Swift or Python to run Aviary. Linux needs system CA certificates for HTTPS, and Chrome cookie extraction needs an unlocked desktop keyring or basic password storage. Firefox and explicit `--auth-token`/`--ct0` credentials also work on headless systems. Ubuntu 22.04, Debian 12, Windows, Alpine, and automatic Snap/Flatpak profile discovery are outside the support matrix for new releases.

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

`mise.toml` pins Swift 6.3.3, Python 3.14.8, and uv 0.12.23. Run `mise install` to install them, or let `mise run` install missing tools automatically. macOS still needs Xcode or Command Line Tools for its SDK. Build tasks always invoke SwiftPM so it can check the selected compiler and SDK as well as source changes; SwiftPM handles incremental builds.

The project configuration leaves released `aviary` and `bird` commands on PATH. Run `mise run aviary -- --help` to build and execute the local release binary, or `mise run run -- --help` for the debug binary. To build without running, use `mise run build` or `mise run build-debug`; the executables and their resources stay in `.build`.

## CI and releases

Normal CI runs the offline Swift tests in debug configuration on macOS ARM64 and Linux x86_64, plus the release-tooling unit tests and Ruff lint and formatting checks. macOS uses the runner's preinstalled Xcode 16.3. Linux uses Ubuntu 24.04 runners and the official `swift:6.1.3-noble` container, which already contains Swift. This older Swift baseline checks compiler compatibility and builds releases; local mise tasks use Swift 6.3.3. Both cache `.build` with image or Xcode, platform, architecture, and dependency namespaces. Neither downloads a separate Swift toolchain or creates release archives on every PR. Linux package installation uses HTTPS repositories, bounded transport timeouts and retries, and only the required packages. CI and release workflows pin uv to 0.12.23 and select Python 3.14.8. Ruff is pinned to 0.17.0 through uv tool commands.

A stable `vMAJOR.MINOR.PATCH` tag runs the release workflow. It tests and builds all four native platforms in release configuration, packages each archive, and checks relocation, bundled resources, symlinks, renamed executables, and missing-resource failures. Using release configuration for both tests and packaging avoids a separate debug build. Linux archives also run in plain Ubuntu 24.04 containers with no network or Swift installation. Separate publication and Homebrew jobs each serialize changes across all release tags, while builds remain parallel. Their concurrency queues retain up to 100 pending jobs. The publication job verifies all four checksums, renders the Homebrew formula, uploads a complete draft, and publishes it. The latest release designation advances only when the candidate is newer than every existing public stable release, comparing numeric versions. Existing public releases are validation-only: reruns never replace their assets or change their latest designation. GitHub isolates caches created for different release tags; changing cache keys does not make those caches reusable across tags.

The Homebrew formula lives in [grahamannett/homebrew-tap](https://github.com/grahamannett/homebrew-tap). Set `HOMEBREW_TAP_TOKEN` in Aviary's Actions secrets to a fine-grained token with contents write permission for that repository to enable automatic formula updates. The Homebrew job downloads the public release's attached formula and verifies its version before updating the tap. Newer candidates advance the formula; an identical formula at the same version is a no-op; a different formula at the same version fails; older candidates leave the newer formula intact. Without the token, the workflow reports that Homebrew still needs updating. The local release task requires automatic tap access and verified tap state before reporting complete success.

Commit feature changes first, then run the release task from a clean `main` checkout:

```sh
mise run release -- 0.2.0
# Continue after an interrupted check, push, or workflow:
mise run release -- 0.2.0 --resume
```

Choose the version explicitly. The task validates Git state and GitHub access, updates the CLI version and installer-test default, runs `mise run ci`, commits the version changes, and pushes main. It waits for successful CI for that exact commit before creating and pushing the matching annotated tag. It then monitors the release and verifies the published assets and Homebrew formula. This command publishes a real release; it does not upgrade your global installation. The completion message includes the explicit mise installation command.

If a stage fails, the task preserves its edits and prints the recovery command and workflow link where applicable. `--resume` reconstructs progress from Git and GitHub without replacing tags or republishing assets. Failed workflows require the printed explicit rerun command before resuming. If publication succeeds but the Homebrew job fails, the release is public and completion is partial. Rerun only the Homebrew job using the printed command, then resume verification; this avoids rebuilding or changing release assets. Polling uses GitHub CLI JSON results, allowing five minutes for a workflow to appear and 60 minutes for completion. Historical verification accepts a newer tap formula only when its bytes match the attached formula from that newer public stable release.

For an existing public release, repair the tap from a current checkout with GitHub authentication and tap push access:

```sh
mise run repair-tap -- 0.2.0
```

This command downloads the published formula, clones the tap into a retained temporary directory, and applies the same version guards. It creates no release build, tag, or asset changes. When using `update-tap --tap-dir` directly, provide a clean checkout of the tap's default branch; its HEAD must match the refreshed live branch before changes begin. Older tags retain their original workflow code; these guards apply to future tags containing the updated workflow. Use `repair-tap` for historical releases instead of rerunning an older workflow's unguarded tap update. Temporary clones remain available for inspection and can be removed with `trash`.

## Release tooling

`scripts/release.py` is a standard-library-only script that runs through uv with Python 3.14.8. It handles archive packaging and validation, formula rendering, bounded Git/GitHub commands, and publication. `publish` implements the local release task above; `package` creates one platform archive; `check` validates an extracted archive offline; `prepare` verifies all four archives and writes `SHA256SUMS` and `aviary.rb`. `publish-assets` handles draft publication and immutable public-release validation in Actions; `update-tap` applies the guarded formula update independently. Ruby is Homebrew's formula format. The checked-in `scripts/templates/aviary.rb.in` contains readable Ruby with Python `string.Template` placeholders for version, repository, archive URLs, and verified checksums; required placeholders fail if missing. The other script, `generate-bird-fixtures.mjs`, maintains the Bird compatibility fixtures.

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

The tooling tests live in `Tests/Distribution/test_release.py` and `Tests/Distribution/test_publish.py`. Run them with `mise run test-release-tooling` and read-only Python checks with `mise run check-python`. `mise run format-python` applies Ruff's safe lint fixes and default formatting to `scripts` and `Tests/Distribution`. `mise run ci` requires the Swift tests, Python checks, and tooling tests to pass. Ruff uses Python 3.14 syntax rules, its default error checks, and import ordering; it is a development tool and adds no runtime dependency.

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

The mise tasks affect only the temporary installation. The Bird check requires mise 2026.10.3 or newer, clears any previous executable-rename option, restores the Aviary installation, configures `wrappers.bird = "aviary"`, and reshims. It verifies both commands report the selected version and that `bird query-ids --json` produces offline resource diagnostics. Homebrew uses its normal system prefix. Set `AVIARY_INSTALL_TEST_VERSION` or `AVIARY_INSTALL_TEST_ROOT` to select a different release or temporary directory; the root must be an absolute path.

## Validation limits

macOS CI runners are newer than macOS 13, so that version still needs a hardware smoke check. Linux desktop authentication needs a read-only manual check with conventional Chrome and Firefox profiles; the offline suite covers cookie fixtures, decryption, fallback, timeout, and missing-keyring behavior.
