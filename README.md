# quick-vpn

> One command to spin up your own WireGuard VPN on a fresh VPS — with QR codes, sane defaults, and friendly output.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen.svg)](https://www.shellcheck.net/)

```console
$ sudo qvpn init
✓ Server keys generated
✓ Client config:  /etc/wireguard/clients/phone.conf
✓ wg-quick@wg0 is running
✓ QR code (PNG) saved → /etc/wireguard/clients/phone_qr.png

━━━━━━━━━━━━━━━━━━━━
  ✓ VPN ready
━━━━━━━━━━━━━━━━━━━━
```

---

## Why

You want a private VPN on your own VPS — no third-party logs, no monthly bill, no
WireGuard documentation deep-dive. `qvpn` packages the boring parts (keys, configs,
firewall, sysctl, systemd) behind a single CLI:

| What you used to do                                | What you do now              |
| -------------------------------------------------- | ---------------------------- |
| Edit two config files, run three scripts in order  | `sudo qvpn init`             |
| `cat`, `wg`, `awk`, `iptables -L` to see who's on  | `sudo qvpn status`           |
| Hand-edit `wg0.conf` to revoke a client            | `sudo qvpn remove <name>`    |

---

## Requirements

- A VPS with a public IP and root access
- Linux: Ubuntu 20.04+ / Debian 11+ (Fedora, RHEL, Arch supported best-effort)
- Open UDP port (default: `51820`) on your provider's firewall

`qvpn` itself only needs `bash`. Server install pulls in `wireguard`, `qrencode`, and `ufw`.

---

## Install

### One-liner (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/baymac/quick-vpn/main/install.sh | sudo bash
```

### From a local checkout

```bash
git clone https://github.com/baymac/quick-vpn.git
cd quick-vpn
sudo ./install.sh
```

### Without installing (one-shot)

```bash
scp qvpn root@your-vps:/root/
ssh root@your-vps
chmod +x ./qvpn
./qvpn init
```

---

## Quick start

```bash
sudo qvpn init                       # set up server + first client (named "phone")
sudo qvpn add laptop                 # add another client; auto-assigns a free IP
sudo qvpn list                       # see all clients
sudo qvpn status                     # service health + live peer state
sudo qvpn show laptop                # re-display QR + config
sudo qvpn remove phone               # revoke a client cleanly
sudo qvpn teardown                   # remove everything
```

After `init`, your terminal shows a QR code. Open the WireGuard mobile app, tap
**+ → Scan from QR code**, enable the tunnel — done. For desktop, copy the printed
config text into a new tunnel.

---

## Commands

| Command           | What it does                                         |
| ----------------- | ---------------------------------------------------- |
| `qvpn init`       | First-time WireGuard setup + create the first client |
| `qvpn add <name>` | Add a new client (auto-assigns IP unless `--ip`)     |
| `qvpn remove <name>` | Revoke a client and delete its files              |
| `qvpn list`       | List all clients with status                         |
| `qvpn show <name>`| Re-display QR / config; supports `--qr-only`, `--conf-only`, `--save FILE` |
| `qvpn status`     | Service health + live peer table (RX/TX/handshake)   |
| `qvpn restart`    | Restart `wg-quick@wg0`                               |
| `qvpn teardown`   | Stop service + remove configs (use `--purge` for full uninstall) |
| `qvpn version`    | Print version                                        |
| `qvpn help [cmd]` | Show help (optionally per-command)                   |

Run `qvpn help <command>` for full flags on any command.

### Global flags

```
-y, --yes              skip confirmation prompts
-q, --quiet            suppress informational output
-v, --verbose          show debug output
    --dry-run          print actions without executing
    --no-color         disable colored output (also: NO_COLOR=1)
    --color WHEN       always | never | auto
-c, --config FILE      use this config file
-V, --version          print version
-h, --help             show help
```

---

## Configuration

`qvpn` works with zero configuration. To override defaults, you have three
options — listed in increasing priority:

1. **Built-in defaults** (subnet `10.0.0.0/24`, port `51820`, DNS `1.1.1.1, 8.8.8.8`)
2. **Config file** (auto-loaded from `./qvpn.conf` or `/etc/wireguard/qvpn.conf`)
3. **CLI flags** (`--listen-port`, `--dns`, `--name`, …)

A config file is just bash-style key=value:

```bash
# /etc/wireguard/qvpn.conf
LISTEN_PORT="41820"
DNS_SERVERS="9.9.9.9, 1.0.0.1"
CLIENT_NAME="phone"
```

See [`qvpn.conf.example`](qvpn.conf.example) for the full list.

After `qvpn init`, the resolved settings are persisted to `/etc/wireguard/.qvpn-meta`
so subsequent commands (`add`, `status`, …) don't need to re-detect or re-prompt.

---

## Common workflows

### Adding a phone

```bash
sudo qvpn add phone
```

Prints a QR code; scan it with the WireGuard mobile app.

### Adding a desktop with a fixed IP

```bash
sudo qvpn add desktop --ip 10.0.0.42
```

Copy the printed config into the WireGuard desktop client (**Manage Tunnels →
Add empty tunnel**).

### Pulling a config to your laptop

```bash
ssh root@your-vps "qvpn show desktop --conf-only" > desktop.conf
```

### Checking who's connected

```bash
sudo qvpn status
```

```
── Peers ──

  NAME                 VPN IP          RX           TX           HANDSHAKE
  ────                 ──────          ──           ──           ─────────
  phone                10.0.0.2        2.34 MB      18.7 MB      12s ago
  laptop               10.0.0.3        1.10 GB      342.5 MB     2m ago
  tv                   10.0.0.4        0 B          0 B          never
```

### Revoking a client

```bash
sudo qvpn remove phone
```

This removes the peer from the live interface, persists the change to
`wg0.conf`, and deletes the client's keys and QR code.

### Tearing it all down

```bash
sudo qvpn teardown                 # soft: keeps packages + IP forwarding
sudo qvpn teardown --purge         # hard: also removes packages
```

---

## Troubleshooting

**Connection works briefly, then drops.**
You're using the same client config on two devices. Each client must be unique —
add a separate one (`qvpn add laptop2`).

**`qvpn add` says "IP is already in use".**
Run `qvpn list` to see what's taken, or omit `--ip` to auto-assign.

**"Could not auto-detect public IP".**
The VPS can't reach the IP-detection endpoints. Pass it explicitly:
`sudo qvpn init --server-ip 1.2.3.4`.

**WireGuard doesn't start after init.**
```bash
sudo qvpn status                    # check service health
sudo journalctl -u wg-quick@wg0 -n 50
```
Common causes: provider firewall blocks UDP/51820, or the host interface
auto-detect picked the wrong NIC. Override with `--interface ens3`.

**Phone scans the QR but won't connect.**
Open the provider firewall for the WireGuard UDP port. If you're behind a NAT,
you may also need port forwarding on the upstream router.

**I want to change the listen port after install.**
Edit `/etc/wireguard/wg0.conf`, run `sudo qvpn restart`, then re-run `sudo ufw
allow <new-port>/udp`. (Or just `sudo qvpn teardown` and `qvpn init --listen-port <port>`.)

---

## Security notes

- Server private key lives in `/etc/wireguard/privatekey` (mode `600`).
- Client private keys live in `/etc/wireguard/clients/<name>_privatekey` (mode `600`).
- Anyone with root on the server has full access to all client configs — that's
  inherent to self-hosted VPNs, not specific to qvpn.
- `qvpn teardown` wipes all keys, so you can't recover client tunnels — re-run
  `qvpn init` and `qvpn add` to create new ones.

---

## Uninstall

```bash
sudo qvpn teardown --purge          # remove WireGuard, configs, packages
sudo /path/to/install.sh uninstall  # remove the qvpn binary itself
```

Or just `sudo rm /usr/local/bin/qvpn`.

---

## Development

`qvpn` is one self-contained bash script (`qvpn`) plus a thin installer.
Hack on it directly:

```bash
git clone https://github.com/baymac/quick-vpn.git
cd quick-vpn
bash -n qvpn                        # syntax check
shellcheck qvpn                     # static analysis (optional)
./qvpn help                         # smoke test (no root needed for help)
```

Test on a real VPS in a throwaway environment — `qvpn teardown --purge` makes
iteration cheap.

---

## License

MIT
