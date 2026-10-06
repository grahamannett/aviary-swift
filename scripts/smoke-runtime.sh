#!/usr/bin/env sh
# Used in clean Ubuntu/Debian containers with no Swift installation or checkout.
set -eu
archive="$1"
if command -v swift >/dev/null 2>&1; then
  echo "Runtime smoke must run without an installed Swift compiler" >&2
  exit 1
fi
task_root="$(mktemp -d)"
install_dir="$task_root/relocated install"
mkdir -p "$install_dir" "$task_root/home" "$task_root/links"
tar -xzf "$archive" -C "$install_dir"
export HOME="$task_root/home"
export XDG_CONFIG_HOME="$HOME/.config"
export AVIARY_SKIP_QUERY_ID_REFRESH=1
unset AUTH_TOKEN CT0 LD_LIBRARY_PATH BIRD_QUERY_IDS_CACHE AVIARY_QUERY_IDS_CACHE BIRD_FEATURES_CACHE AVIARY_FEATURES_CACHE
cd "$task_root"
"$install_dir/bin/aviary" --help >/dev/null
"$install_dir/libexec/aviary-selftest" --resources-only
"$install_dir/bin/aviary" query-ids --json
ln -s "$install_dir/bin/aviary" "$task_root/links/bird"
"$task_root/links/bird" query-ids --json >/dev/null
mv "$install_dir/bin/aviary" "$install_dir/bin/bird"
"$install_dir/bin/bird" query-ids --json >/dev/null
mv "$install_dir/bin/bird" "$install_dir/bin/aviary"
mv "$install_dir/bin/Aviary_XClient.resources" "$task_root/hidden-resources"
if "$install_dir/libexec/aviary-selftest" --resources-only; then
  echo "Missing resources incorrectly passed diagnostics" >&2
  exit 1
fi
mv "$task_root/hidden-resources" "$install_dir/bin/Aviary_XClient.resources"
"$install_dir/libexec/aviary-selftest" --resources-only
echo "Clean runtime smoke passed without Swift"
