#!/usr/bin/env bash
#
# qvpn installer — drops the qvpn binary into your $PATH.
#
# Usage:
#   sudo ./install.sh                  # install
#   sudo ./install.sh uninstall        # remove
#   curl -fsSL <raw-url>/install.sh | sudo bash    # remote install

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
TARGET="${INSTALL_DIR}/qvpn"
REMOTE_URL="${QVPN_INSTALL_URL:-https://raw.githubusercontent.com/baymac/quick-vpn/main/qvpn}"

cyan()   { printf '\033[0;36m%s\033[0m' "$1"; }
green()  { printf '\033[0;32m%s\033[0m' "$1"; }
red()    { printf '\033[0;31m%s\033[0m' "$1"; }
yellow() { printf '\033[1;33m%s\033[0m' "$1"; }

err()  { red   "[error] "; printf '%s\n' "$1" >&2; exit 1; }
log()  { cyan  "[info]  "; printf '%s\n' "$1"; }
ok()   { green "[ok]    "; printf '%s\n' "$1"; }
warn() { yellow "[warn]  "; printf '%s\n' "$1"; }

require_root() {
    if (( EUID != 0 )); then
        err "This installer must be run as root. Try: sudo ./install.sh ${1:-}"
    fi
}

uninstall() {
    require_root uninstall
    if [[ -f "$TARGET" ]]; then
        rm -f "$TARGET"
        ok "Removed $TARGET"
    else
        warn "qvpn was not installed at $TARGET"
    fi
    if [[ -d /etc/wireguard ]]; then
        warn "Note: /etc/wireguard still exists. Run 'sudo qvpn teardown' first to clean up VPN config."
    fi
}

install() {
    require_root install

    if [[ ! -d "$INSTALL_DIR" ]]; then
        err "$INSTALL_DIR does not exist. Set INSTALL_DIR=<path> to choose another directory."
    fi

    local source=""
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""

    if [[ -n "$script_dir" && -f "${script_dir}/qvpn" ]]; then
        source="${script_dir}/qvpn"
        log "Installing from local checkout: $source"
        install -m 0755 "$source" "$TARGET"
    else
        log "Downloading qvpn from $REMOTE_URL"
        if ! command -v curl >/dev/null 2>&1; then
            err "curl is required for remote install. Install curl, or run from a local checkout."
        fi
        local tmp; tmp=$(mktemp)
        if ! curl -fsSL "$REMOTE_URL" -o "$tmp"; then
            rm -f "$tmp"
            err "Failed to download $REMOTE_URL"
        fi
        if ! head -n1 "$tmp" | grep -q '^#!.*bash'; then
            rm -f "$tmp"
            err "Downloaded file doesn't look like a bash script. Aborting."
        fi
        install -m 0755 "$tmp" "$TARGET"
        rm -f "$tmp"
    fi

    ok "qvpn installed → $TARGET"

    # Verify it works
    if "$TARGET" version >/dev/null 2>&1; then
        local version
        version=$("$TARGET" version 2>&1 | head -n1)
        ok "$version"
    else
        warn "qvpn was installed but failed a basic version check."
    fi

    cat <<EOF

Next steps:
  $(green 'sudo qvpn init')           # set up WireGuard + first client
  $(cyan  'qvpn help')                # see all commands

EOF
}

case "${1:-install}" in
    install)            install ;;
    uninstall|remove)   uninstall ;;
    -h|--help|help)
        cat <<EOF
qvpn installer

Usage:
  sudo ./install.sh                install qvpn into $INSTALL_DIR
  sudo ./install.sh uninstall      remove qvpn

Environment:
  INSTALL_DIR        target directory (default: /usr/local/bin)
  QVPN_INSTALL_URL   override remote URL when running via curl|bash
EOF
        ;;
    *)
        err "Unknown command: $1 (try: install | uninstall | help)"
        ;;
esac
