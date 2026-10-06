#!/usr/bin/env bash
# Generate a reviewable tap checkout; this script does not create or push a repository.
set -euo pipefail

if [[ $# -eq 2 && "$1" == --head ]]; then
  tap_dir="$2"
  script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
  mkdir -p "$tap_dir/Formula"
  cp "$script_dir/../Formula/aviary.rb" "$tap_dir/Formula/aviary.rb"
elif [[ $# -eq 3 ]]; then
  version="$1"
  checksums="$2"
  tap_dir="$3"
  script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
  mkdir -p "$tap_dir/Formula"
  uv run --no-project --python 3.14 python "$script_dir/render-homebrew-formula.py" \
    --version "$version" --checksums "$checksums" --output "$tap_dir/Formula/aviary.rb"
else
  echo "Usage: $0 VERSION SHA256SUMS TAP_DIRECTORY | --head TAP_DIRECTORY" >&2
  exit 2
fi
if [[ ! -e "$tap_dir/README.md" ]]; then
  cat > "$tap_dir/README.md" <<'EOF'
# Graham's Homebrew tap

Install Aviary with `brew install grahamannett/tap/aviary`.

This tap installs prebuilt macOS and Linux releases from [aviary-swift](https://github.com/grahamannett/aviary-swift). No Swift compiler is needed. The release workflow updates `Formula/aviary.rb` from the published release checksums.

Before the first binary release, macOS users can build the latest source with `brew install --HEAD grahamannett/tap/aviary` and Xcode 16.3 or later.

See [distribution documentation](https://github.com/grahamannett/aviary-swift/blob/main/docs/distribution.md) for supported platforms and optional `bird` compatibility.
EOF
fi
printf 'Tap files prepared at %s\n' "$tap_dir"
