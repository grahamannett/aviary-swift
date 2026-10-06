#!/usr/bin/env bash
# Install a native source build; downloaded releases include Linux runtimes too.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 BUILD_DIRECTORY INSTALL_PREFIX" >&2
  exit 2
fi
build_dir="$1"
prefix="$2"
destination="$prefix/libexec/aviary"
command_path="$prefix/bin/aviary"
if [[ -e "$command_path" || -L "$command_path" ]]; then
  if [[ ! -L "$command_path" || "$(readlink "$command_path")" != "../libexec/aviary/bin/aviary" ]]; then
    echo "Refusing to overwrite $command_path; choose another AVIARY_INSTALL_PREFIX." >&2
    exit 1
  fi
fi
bundles=()
for bundle in "$build_dir"/Aviary_XClient.bundle "$build_dir"/Aviary_XClient.resources; do
  if [[ -d "$bundle" ]]; then bundles+=("$bundle"); fi
done
if [[ ${#bundles[@]} -ne 1 || ! -x "$build_dir/aviary" || ! -x "$build_dir/AviarySelfTest" ]]; then
  echo "Build aviary and AviarySelfTest with their resource bundle before installing." >&2
  exit 1
fi
mkdir -p "$destination/bin" "$destination/libexec" "$prefix/bin"
cp "$build_dir/aviary" "$destination/bin/aviary"
cp "$build_dir/AviarySelfTest" "$destination/libexec/aviary-selftest"
cp -R "${bundles[0]}" "$destination/bin/"
"$destination/libexec/aviary-selftest" --resources-only
if [[ ! -L "$command_path" ]]; then
  ln -s ../libexec/aviary/bin/aviary "$command_path"
fi
printf 'Installed Aviary at %s\n' "$command_path"
