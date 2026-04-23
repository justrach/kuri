#!/usr/bin/env sh
# kuri release-channel installer — https://github.com/justrach/kuri
# Usage: curl -fsSL https://raw.githubusercontent.com/justrach/kuri/release-channel/stable/install.sh | sh
set -e

REPO="justrach/kuri"
CHANNEL="${KURI_CHANNEL:-stable}"
BASE_URL="${KURI_RELEASE_BASE:-https://raw.githubusercontent.com/${REPO}/release-channel/${CHANNEL}}"
INSTALL_DIR="${KURI_INSTALL_DIR:-$HOME/.local/bin}"

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin) OS_NAME="macos" ;;
  Linux) OS_NAME="linux" ;;
  *) echo "Unsupported OS: $OS" >&2; exit 1 ;;
esac

case "$ARCH" in
  x86_64|amd64) ARCH_NAME="x86_64" ;;
  arm64|aarch64) ARCH_NAME="aarch64" ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

TARGET="${ARCH_NAME}-${OS_NAME}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MANIFEST_URL="${BASE_URL}/latest.json"
echo "Fetching kuri ${CHANNEL} channel manifest..."
curl -fsSL "$MANIFEST_URL" -o "$TMP/latest.json"

VERSION="$(grep '"version"' "$TMP/latest.json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')"
ASSET_BLOCK="$(sed -n "/\"${TARGET}\"[[:space:]]*:/,/}/p" "$TMP/latest.json")"
URL="$(printf '%s\n' "$ASSET_BLOCK" | grep '"url"' | head -1 | sed 's/.*"url": *"\([^"]*\)".*/\1/')"
SHA256="$(printf '%s\n' "$ASSET_BLOCK" | grep '"sha256"' | head -1 | sed 's/.*"sha256": *"\([^"]*\)".*/\1/')"

if [ -z "$VERSION" ] || [ -z "$URL" ]; then
  echo "Error: no ${TARGET} asset in ${MANIFEST_URL}" >&2
  exit 1
fi

echo "Installing kuri ${VERSION} (${TARGET})..."
curl -fL "$URL" -o "$TMP/kuri.tar.gz"

if [ -n "$SHA256" ]; then
  if command -v shasum >/dev/null 2>&1; then
    ACTUAL="$(shasum -a 256 "$TMP/kuri.tar.gz" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "$TMP/kuri.tar.gz" | awk '{print $1}')"
  else
    ACTUAL=""
  fi
  if [ -n "$ACTUAL" ] && [ "$ACTUAL" != "$SHA256" ]; then
    echo "Error: checksum mismatch for ${TARGET}" >&2
    exit 1
  fi
fi

tar -xzf "$TMP/kuri.tar.gz" -C "$TMP"
mkdir -p "$INSTALL_DIR"

BINS="kuri kuri-agent kuri-fetch kuri-browse"
INSTALLED=""
for BIN in $BINS; do
  if [ -f "$TMP/$BIN" ]; then
    cp "$TMP/$BIN" "$INSTALL_DIR/$BIN"
    chmod +x "$INSTALL_DIR/$BIN"
    if [ "$OS_NAME" = "macos" ]; then
      xattr -d com.apple.quarantine "$INSTALL_DIR/$BIN" 2>/dev/null || true
    fi
    INSTALLED="$INSTALLED $BIN"
  fi
done

echo ""
echo "Installed:$INSTALLED"
echo "Location:  $INSTALL_DIR"
echo "Channel:   $CHANNEL"
echo "Version:   $VERSION"
echo ""

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    echo "Add to your shell profile:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
    ;;
esac

echo "Quick start:"
echo "  kuri --help"
echo "  kuri-agent tabs"
echo ""
echo "Docs: https://github.com/${REPO}"
