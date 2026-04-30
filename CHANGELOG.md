# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-04-30

First production release. The four legacy scripts (`wireguard_init`,
`wireguard_client_add`, `wireguard_client`, `wireguard_teardown`) are replaced
with a single unified CLI named `qvpn`.

### Added
- Single-file `qvpn` CLI with subcommands:
  - `qvpn init` — first-time WireGuard setup with sensible defaults
  - `qvpn add` — add a client (auto-assigns next free IP if `--ip` omitted)
  - `qvpn remove` — revoke a client and clean up keys, configs, QR PNG, and
    the matching `[Peer]` block
  - `qvpn list` — list all clients with active/configured status; `--json` output
  - `qvpn show` — re-display QR + config; `--qr-only`, `--conf-only`, `--save FILE`
  - `qvpn status` — service health and live peer table (RX/TX, last handshake)
  - `qvpn restart` — restart the WireGuard service
  - `qvpn teardown` — soft teardown by default; `--purge` for full uninstall
  - `qvpn version`, `qvpn help [cmd]`
- Global flags: `--yes`, `--quiet`, `--verbose`, `--dry-run`, `--no-color`,
  `--color {always|never|auto}`, `--config FILE`
- `install.sh` installer: works locally or via `curl|sudo bash`; supports
  `uninstall`
- State file at `/etc/wireguard/.qvpn-meta` so `add`/`status`/`show` don't
  need to re-detect server IP every run
- Multi-distro package install (Debian/Ubuntu, Fedora/RHEL, Arch best-effort)
- Single config file at `/etc/wireguard/qvpn.conf` (was two separate files)
- `qvpn.conf.example` with documented options
- Production-quality README with troubleshooting and dev sections

### Changed
- Teardown is now soft by default (keeps packages + IP forwarding). Use
  `--purge` to fully uninstall — previously the old script aggressively
  removed packages with separate prompts.
- IP forwarding is persisted to `/etc/sysctl.d/99-qvpn-wireguard.conf` instead
  of being appended to `/etc/sysctl.conf` (cleanly removable on teardown).
- Public-IP detection has timeouts and tries multiple endpoints (was a single
  blocking `curl ifconfig.me`).
- All log/error formatting unified across commands; respects `NO_COLOR` env
  var and falls back to plain text on non-TTY output.
- Dropped runtime dependency on the `boxes` utility — banners are drawn with
  built-in characters.

### Fixed
- Greedy regex (`.*=`) in config parsers truncated WireGuard public keys
  ending in `=`. Now uses `^[^=]*=` (up-to-first-equals).
- Peer-block accumulation in `awk` parsers no longer drops the last peer when
  multiple `[Peer]` sections appear consecutively.
- `qvpn add` registers the new peer on the running interface via `wg set`,
  so connections work without a service restart.
- Client name validation rejects whitespace and shell meta-characters.

### Removed
- Legacy entry points: `wireguard_init`, `wireguard_init.conf`,
  `wireguard_client_add`, `wireguard_client_add.conf`, `wireguard_client`,
  `wireguard_teardown`. Use `qvpn <subcommand>` instead.
