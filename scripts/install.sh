#!/bin/sh
# Installs the `silth` CLI from the GitHub releases of silthhq/framework.
#
#   curl -fsSL https://silth.dev/install.sh | sh
#   curl -fsSL https://silth.dev/install.sh | SILTH_VERSION=0.1.0 sh
#
# Environment:
#   SILTH_VERSION       version to install (default: the latest release)
#   SILTH_INSTALL_DIR   where to put the binary (default: ~/.silth/bin)
#   SILTH_DOWNLOAD_URL  base URL of the release files (default: GitHub releases)
#
# The archive is checked against the release's SHA256SUMS before anything is
# installed. Silth apps are compiled with Crystal: install it too
# (https://crystal-lang.org/install).
set -eu

repo="https://github.com/silthhq/framework/releases"
version="${SILTH_VERSION:-}"
version="${version#v}"
install_dir="${SILTH_INSTALL_DIR:-$HOME/.silth/bin}"

say() { printf '%s\n' "$*"; }
fail() { printf 'silth install: %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) fail "unsupported system $(uname -s): build from source (https://silth.dev/docs/getting-started/installation)" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=$([ "$os" = darwin ] && echo arm64 || echo aarch64) ;;
  *) fail "unsupported architecture $(uname -m)" ;;
esac
asset="silth-$os-$arch.tar.gz"

if [ -n "${SILTH_DOWNLOAD_URL:-}" ]; then
  base="${SILTH_DOWNLOAD_URL%/}"
elif [ -n "$version" ]; then
  base="$repo/download/v$version"
else
  base="$repo/latest/download"
fi

if command -v curl > /dev/null 2>&1; then
  fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
elif command -v wget > /dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
else
  fail "curl or wget is required"
fi

if command -v sha256sum > /dev/null 2>&1; then
  checksum() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum > /dev/null 2>&1; then
  checksum() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
  fail "sha256sum or shasum is required to check the download"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

say "Downloading $asset${version:+ ($version)}…"
fetch "$base/$asset" "$tmp/$asset" || fail "cannot download $base/$asset"
fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" || fail "cannot download $base/SHA256SUMS"

expected="$(grep " $asset\$" "$tmp/SHA256SUMS" | cut -d ' ' -f 1)"
[ -n "$expected" ] || fail "$asset is not listed in SHA256SUMS"
actual="$(checksum "$tmp/$asset")"
[ "$expected" = "$actual" ] || fail "checksum mismatch for $asset (expected $expected, got $actual)"

tar -xzf "$tmp/$asset" -C "$tmp"
mkdir -p "$install_dir"
install -m 755 "$tmp/silth" "$install_dir/silth"
say "Installed $("$install_dir/silth" version) in $install_dir/silth"

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *) say "Add it to your PATH, for example in ~/.profile:"
     say "  export PATH=\"$install_dir:\$PATH\"" ;;
esac
command -v crystal > /dev/null 2>&1 || say "Silth apps are compiled with Crystal 1.22+: https://crystal-lang.org/install"
