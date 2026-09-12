# aviary-swift

Swift rewrite of Bird 0.8 as a native macOS CLI named `aviary`. Same commands, flags, cookie auth (`auth_token` / `ct0`), GraphQL/REST, and config paths (`~/.config/bird`, `./.birdrc.json5`). Browser cookie decrypt is implemented in Swift (Safari binarycookies, Chrome sqlite + Keychain, Firefox sqlite). No Node/Bun at runtime.

## Requirements

- macOS 13+
- Swift 5.10+ (Xcode Command Line Tools)
- [mise](https://mise.jdx.dev/) for the tasks in `mise.toml`

## Build and run

```bash
cd aviary-swift
mise run test
mise run build
mise run aviary -- --help
mise run aviary -- --cookie-source chrome whoami
```

The binary is copied to `.build/release/aviary`.

## Homebrew (local formula)

```bash
brew install --build-from-source Formula/aviary.rb
```

## Notes

- Executable name is `aviary`, not `bird`.
- Cookie extraction is macOS-only in this tree.
- Safari may need Full Disk Access for Terminal (or the app that launches `aviary`).
