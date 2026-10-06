#!/usr/bin/env bash
# Install the signed native Swift toolchain used by Ubuntu 22.04 ARM64 CI.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 NEW_TOOLCHAIN_DIRECTORY" >&2
  exit 2
fi
if [[ "$(uname -s)" != Linux || "$(uname -m)" != aarch64 ]]; then
  echo "This installer requires a native Linux ARM64 host" >&2
  exit 1
fi

toolchain_dir="$1"
if [[ -e "$toolchain_dir" ]]; then
  echo "Refusing to overwrite existing toolchain directory: $toolchain_dir" >&2
  exit 1
fi
mkdir -p "$toolchain_dir/downloads" "$toolchain_dir/gnupg"
chmod 700 "$toolchain_dir/gnupg"

archive_name="swift-6.1.3-RELEASE-ubuntu22.04-aarch64.tar.gz"
archive_url="https://download.swift.org/swift-6.1.3-release/ubuntu2204-aarch64/swift-6.1.3-RELEASE/$archive_name"
signing_fingerprint="52BB7E3DE28A71BE22EC05FFEF80A866B47A981F"
key_file="$toolchain_dir/downloads/swift-release-key.asc"
archive_file="$toolchain_dir/downloads/$archive_name"

curl --fail --location --retry 3 "$archive_url" --output "$archive_file"
curl --fail --location --retry 3 "$archive_url.sig" --output "$archive_file.sig"
curl --fail --location --retry 3 https://www.swift.org/keys/release-key-swift-6.x.asc --output "$key_file"
actual_fingerprint="$(gpg --batch --homedir "$toolchain_dir/gnupg" --show-keys --with-colons "$key_file" | awk -F: '$1 == "fpr" { print $10; exit }')"
if [[ "$actual_fingerprint" != "$signing_fingerprint" ]]; then
  echo "Unexpected Swift release signing-key fingerprint: $actual_fingerprint" >&2
  exit 1
fi
gpg --batch --homedir "$toolchain_dir/gnupg" --import "$key_file"
gpg --batch --homedir "$toolchain_dir/gnupg" --verify "$archive_file.sig" "$archive_file"
tar -xzf "$archive_file" --directory "$toolchain_dir" --strip-components=1

version_output="$("$toolchain_dir/usr/bin/swift" --version)"
if [[ "$version_output" != *"Swift version 6.1.3"* || "$version_output" != *"Target: aarch64-unknown-linux-gnu"* ]]; then
  echo "Expected Swift 6.1.3 targeting native aarch64 Linux; received:" >&2
  echo "$version_output" >&2
  exit 1
fi
echo "$version_output"
