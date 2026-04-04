#!/bin/sh
set -e

BASE_URL="https://github.com/acopy-org/client/releases/latest/download"
BIN="acopy"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "unsupported architecture: $ARCH"; exit 1 ;;
esac

# macOS: /usr/local/bin, Linux: ~/.local/bin
if [ "$OS" = "darwin" ]; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
fi

URL="${BASE_URL}/${BIN}-${OS}-${ARCH}"

echo "downloading acopy for ${OS}/${ARCH}..."
curl -fL --progress-bar "$URL" -o "/tmp/${BIN}"
chmod +x "/tmp/${BIN}"

if [ "$OS" = "darwin" ]; then
    xattr -d com.apple.quarantine "/tmp/${BIN}" 2>/dev/null || true
fi

echo "installing to ${INSTALL_DIR}/${BIN}..."
if [ -w "$INSTALL_DIR" ]; then
    mv "/tmp/${BIN}" "${INSTALL_DIR}/${BIN}"
else
    sudo mv "/tmp/${BIN}" "${INSTALL_DIR}/${BIN}"
fi

# Ensure ~/.local/bin is in PATH for Linux
if [ "$OS" != "darwin" ]; then
    case ":$PATH:" in
        *":$INSTALL_DIR:"*) ;;
        *)
            echo ""
            echo "note: add ${INSTALL_DIR} to your PATH if not already:"
            echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
            ;;
    esac
fi

echo "installed. running setup..."
"${INSTALL_DIR}/${BIN}" setup
