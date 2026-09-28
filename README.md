# aviary-swift

A macOS CLI for reading and posting on X, written in Swift. Aims to match Bird 0.8's commands and output. No Node.js or Bun required.

## Requirements

- macOS 13+
- Swift 5.10+ (Xcode Command Line Tools)
- [mise](https://mise.jdx.dev/) for the tasks in `mise.toml`

## Build and run

```bash
mise run test
mise run build
mise run aviary -- --help
mise run aviary -- --cookie-source chrome whoami
```

The binary is at `.build/release/aviary`. Tests run offline with fixtures; they don't access your browser cookies or X account.

## Authentication and config

Aviary reads login cookies from Safari, Chrome, or Firefox. Use `--cookie-source` to choose a browser, or pass `--auth-token` and `--ct0` directly. Safari may require Full Disk Access for your terminal.

Reads Bird config from `~/.config/bird/config.json5` and `./.birdrc.json5`. Caches are separate, under `$XDG_CONFIG_HOME/aviary` or `~/.config/aviary`.

See [Bird compatibility](docs/bird-compatibility.md) for command coverage and differences. For scripts: `read --json` returns one object, not an array; paginated results include `nextCursor`.

## Homebrew (local formula)

```bash
brew install --build-from-source Formula/aviary.rb
```
