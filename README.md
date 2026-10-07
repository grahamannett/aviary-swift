# aviary-swift

A CLI for reading and posting on X, written in Swift. Matches Bird 0.8's commands and output on macOS and Linux. No Node.js or Bun required.

## Install

Published releases provide Apple Silicon and Intel macOS binaries, and arm64 and x86_64 Linux binaries for Ubuntu 22.04/24.04 and Debian 12. Prebuilt releases do not require a Swift compiler.

Install with Homebrew or mise:

```bash
brew install grahamannett/tap/aviary
# Or use mise:
mise use -g github:grahamannett/aviary-swift@0.1.0
aviary --help
```

See [distribution](docs/distribution.md) for release setup, manual downloads, supported Linux browser profiles, and optional `bird` compatibility. Installing Aviary does not replace existing Bird executables automatically.

## Build from source

- macOS 13+ or a supported Linux distribution
- Swift 6.1+ (Xcode Command Line Tools on macOS, or the Swift Linux toolchain)
- On Linux: SQLite development headers and `pkg-config` (`sudo apt install libsqlite3-dev pkg-config`)
- [mise](https://mise.jdx.dev/) for the tasks in `mise.toml`

```bash
mise run test
mise run build
mise run aviary -- --help
mise run aviary -- --cookie-source chrome whoami
```

The binary is at `.build/release/aviary`. Its adjacent `Aviary_XClient.bundle` (macOS) or `Aviary_XClient.resources` (Linux) must accompany it. Run source builds with `mise run aviary`; use Homebrew or mise's GitHub backend for installation. Source builds on Linux use your existing Swift runtime; downloadable Linux releases bundle that runtime. Tests run offline with fixtures; they don't access your browser cookies or X account.

## Authentication and config

Aviary reads login cookies from Safari, Chrome, or Firefox on macOS, and Chrome or Firefox on Linux. Use `--cookie-source` to choose a browser, or pass `--auth-token` and `--ct0` directly. Safari may require Full Disk Access for your terminal. Linux Chrome uses `secret-tool` from `libsecret-tools` for desktop keyring access; Firefox and explicit credentials also work on headless systems.

Reads Bird config from `~/.config/bird/config.json5` and `./.birdrc.json5`. Caches are separate, under `$XDG_CONFIG_HOME/aviary` or `~/.config/aviary`.

See [Bird compatibility](docs/bird-compatibility.md) for command coverage and differences. For scripts: `read --json` returns one object, not an array; paginated results include `nextCursor`.
