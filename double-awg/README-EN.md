# DoubleAWG on AmneziaWG

[RUS](README.md) [ENG](README-EN.md)

`deploy-doubleawg.sh` sets up a cascaded VPN (DoubleAWG) across two Ubuntu 24.04 VPSes using [AmneziaWG](https://docs.amnezia.org/documentation/amnezia-wg/) as a kernel module. You run the script on your own machine (Linux or WSL), and it configures both servers over SSH.

```
Clients ──IPv4──▶ VPS1 [gate1 … gateN │ inway] ══IPv6══▶ VPS2 [outway] ──IPv4/NAT──▶ Internet
                        │
                        └── split: Russian IPs go out directly from VPS1
```

- **Channel**: the tunnel between `inway` (VPS1) and `outway` (VPS2). Addresses inside the Channel are IPv6 ULA, and the transport between the servers is IPv6. If IPv6 is unavailable, the script offers IPv4 instead. VPS2 reaches the internet over IPv4 with NAT.
- **Entry interfaces** (`gate1`, `gate2`, …): where clients connect on VPS1. Each one has its own AmneziaWG version, port, subnet, MTU, connection mode and split setting.
- **Kill switch**: client traffic can only leave through the Channel. If the Channel is down, the traffic is blocked instead of going out from the entry server's IP.
- **Split routing** (set per entry interface): traffic to Russian IPv4 networks leaves directly from VPS1, and everything else goes through the Channel.

## Features

- Installs the current AmneziaWG from the official `ppa:amnezia/ppa` (kernel module built with DKMS). If loading the module requires a reboot, the script reboots the VPS (after asking you) and then carries on.
- Protocol versions **1, 1.5, 2, 3 and 3.1**, chosen separately for the Channel and for each entry interface.
- Keys for the initial setup are generated locally with `wg` and saved, labelled, in the result file.
- Detects each node's network interfaces and addresses, and asks you to confirm them.
- Two entry-interface modes:
  - `listen`: clients connect to the server (phones, laptops);
  - `connect`: the server connects to the client. Use this for a router with a public IP: the client config gets a `ListenPort` and the server gets the client's `Endpoint`.
- Each entry interface has its own subnet (`/8`…`/30`), and the subnets don't have to be adjacent. VPS2 doesn't need to know the client subnets, so you can add entry interfaces later without touching VPS2.
- Management scripts on the servers: add or remove an entry interface, add or remove a client, remove the Channel.
- ufw rules (if ufw is installed), tagged `DoubleAWG`.

## Requirements

**Your machine**: Linux or WSL, bash 4.4+, `ssh` with key-based access to both VPSes, `wireguard-tools` (the `wg` command), `tar`.

**VPSes**:
- Ubuntu 24.04 on KVM or bare metal. OpenVZ and LXC can't load kernel modules.
- `root`, or a user with `sudo`. If sudo needs a password, the script asks for it during installation.
- For IPv6 transport, VPS2 needs a public IPv6 address and VPS1 needs a default IPv6 route.
- A stock Ubuntu kernel. If there are no `linux-headers` for the running kernel, the script installs the current kernel and offers to reboot.
- Secure Boot must be off. Otherwise the kernel refuses to load the unsigned DKMS module.

## Quick start

```bash
chmod +x deploy-doubleawg.sh
./deploy-doubleawg.sh
```

You can preset the defaults with `ENTRY_SSH`, `EXIT_SSH`, `ENTRY_SSH_PORT`, `EXIT_SSH_PORT` and `OUT_DIR`:

```bash
ENTRY_SSH=root@203.0.113.10 EXIT_SSH=root@198.51.100.20 ./deploy-doubleawg.sh
```

### What the script asks

| Step | Question | Default |
|---|---|---|
| SSH | `user@host` and port for VPS1 (entry) and VPS2 (exit) | — / `22` |
| Nodes | confirm the detected interfaces and public IPv4/IPv6 addresses | auto-detected |
| Names | Channel exit (VPS2), Channel entry (VPS1), prefix for entry interfaces | `outway`, `inway`, `gate` |
| Channel | AmneziaWG version, `outway` UDP port, client DNS, I1 (QUIC mimicry) | `2`, random, `1.1.1.1, 1.0.0.1`, yes |
| Entry N | AWG version, subnet, mode, UDP port, split, first client name; for `connect`, the client's `host:port` | Channel version, `10.8.N.0/24`, `listen`, random, yes, `client1` |
| | "Add another entry interface?" | no |

Before installing, the script shows a summary and asks for confirmation. It sets up VPS2 first, then VPS1. At the end it checks that the Channel is up: there's a handshake and ping6 works between the addresses inside the Channel.

### Output

The script creates a `doubleawg-YYYYMMDD-HHMMSS/` folder with permissions `700`:

| File | Contents |
|---|---|
| `doubleawg-result.txt` | nodes, addressing, all keys and obfuscation parameters (labelled), management commands |
| `<interface>-<client>.conf` | configs for the first clients, e.g. `gate1-client1.conf` |
| `servers/entry/`, `servers/exit/` | copies of the configs and scripts installed on the servers |

**These files contain private keys.** Treat them like passwords.

## AmneziaWG versions

| Version | Config parameters |
|---|---|
| 1 | `Jc`, `Jmin`, `Jmax`, `S1`, `S2`, `H1`–`H4` (single values) |
| 1.5 | version 1 + `I1` |
| 2 | + `S3`, `S4`, `H1`–`H4` as ranges |
| 3 | + `HeaderProtectionKey`, `ContentPaddingAddition`; `S1`–`S4` ≥ 12, `H1`–`H4` = 1…4 |
| 3.1 | version 3 + `RandomTrailers`, `DisableCookies` |

How the parameters are chosen:
- values are random but stay within the protocol's constraints: handshake packet sizes never collide, `H` ranges don't overlap, and `Jmax` ≤ 1280;
- `I1` is a packet sent before the handshake that looks like a QUIC Initial packet (1200 bytes);
- the version 3 timers (`RekeyAfterTime` and others) aren't set, so the WireGuard defaults apply.

Each config is tested on a temporary interface before it goes live. If the server's module doesn't support the chosen version's parameters, installation stops with a clear error.

Versions 3 and 3.1 only work with recent clients (AmneziaVPN 5.0.1.5+). Many routers and older apps support version 2 at most.

## Server-side management

The scripts sit next to the configs in `/etc/amnezia/amneziawg/`. Run them with `sudo`.

### VPS1 (entry)

The scripts aren't on `PATH`, so call them by their full path:

```bash
D=/etc/amnezia/amneziawg

# entry interfaces: interactive, or with options
sudo $D/dawg-gate-add.sh
sudo $D/dawg-gate-add.sh --awg 2 --mode listen --net 192.168.181.0/24 --port 40005 --split yes --yes
sudo $D/dawg-gate-add.sh --help
sudo $D/dawg-gate-del.sh gate2                        # removes its clients too

# clients
sudo $D/dawg-client-add.sh gate1 phone                # listen: prints the config and a QR code (if qrencode is installed)
sudo $D/dawg-client-add.sh gate2 router --endpoint home.example.net:51820   # connect
sudo $D/dawg-client-del.sh gate1 phone

# split routing
sudo $D/dawg-entry.sh split-status
sudo $D/dawg-entry.sh split-up gate1
sudo $D/dawg-entry.sh split-down gate1
sudo $D/dawg-entry.sh split-update                    # refresh the list of Russian networks

# remove the Channel, all entry interfaces and the timer (--purge also removes the AmneziaWG packages and the PPA)
sudo $D/dawg-channel-del.sh [--purge]
```

`dawg-gate-add.sh` options:

| Option | Meaning |
|---|---|
| `--awg` | `1`, `1.5`, `2`, `3`, `3.1` (default: the Channel's version) |
| `--mode` | `listen` or `connect` |
| `--net` | client subnet `A.B.C.D/N`, N from 8 to 30. The server takes the first address. Must not overlap other entry interfaces or the server's routes |
| `--port` | UDP port (default: a random free port) |
| `--mtu` | MTU for the interface and its clients (default **1280**) |
| `--dns`, `--split yes\|no`, `--i1 yes\|no`, `--num N`, `--yes` | DNS, split, I1, interface number, no prompts |

Client configs are saved in `/etc/amnezia/amneziawg/clients/<interface>/<client>.conf`. For interfaces and clients added later, the server generates the keys (`awg genkey`).

### VPS2 (exit)

```bash
sudo /etc/amnezia/amneziawg/dawg-channel-del.sh [--purge]
```

## Split routing

Two lines in an entry interface's `.conf` turn split routing on or off:

```ini
PostUp = /etc/amnezia/amneziawg/dawg-entry.sh split-up gate1
PostDown = /etc/amnezia/amneziawg/dawg-entry.sh split-down gate1
```

Comment or uncomment both lines, then run `sudo systemctl restart awg-quick@gate1`. To switch without a restart, use `split-up` and `split-down`.

- **Network list**: Russian IPv4 networks are taken from RIPE NCC delegated stats, with RIPEstat and ipdeny as fallbacks, then merged. The list lives in `dawg-ru.txt`, and `dawg-ru-update.timer` refreshes it weekly.
- **Your own exceptions**: put networks that should go direct in `dawg-ru-extra.txt`, and networks that should always go through the Channel in `dawg-ru-exclude.txt`. Run `split-update` after editing.
- **Accuracy**: the list is based on where a network is registered, not where its addresses actually are.
- **DNS**: with `1.1.1.1`, DNS queries go through the Channel, so Russian sites on CDNs may resolve to foreign addresses. With a Russian resolver (e.g. `77.88.8.8`) those sites go direct, but your DNS queries become visible in Russia.

## MTU

| Segment | MTU |
|---|---|
| Entry interfaces and clients | **1280** by default (`--mtu`). Reliable on mobile networks too. 1380 cuts overhead by about 7%, but the outer packet grows to 1448 bytes, which some networks drop |
| Channel (`inway`/`outway`) | computed from the external interfaces' MTU, the transport header size (80 bytes for IPv6, 60 for IPv4) and `S4`; usually 1400 |

TCP MSS clamping is enabled on both VPSes. The client's MTU must match its entry interface's MTU.

## How it works

**VPS1:**
- Each entry interface `gateN` gets its own routing table `7100+N` (`ip rule` priorities 31000/31001). The table holds `default dev inway`, plus a `blackhole` route that takes over when the Channel is down (kill switch).
- Split routing adds `throw` routes for Russian networks to that table, plus NAT through the external interface.
- Each interface's firewall rules are added in `PostUp` and removed in `PostDown` (`dawg-entry.sh`).

**VPS2:**
- Connections that arrive from `outway` are marked (`CONNMARK 0x444e0000/0xffff0000`), and NAT is applied by that mark.
- Replies, and VPS2's own ICMP packets (traceroute), are routed back into the Channel through table `7100` using the mark.

**rp_filter**: the Channel interfaces have no IPv4 address, so reverse-path filtering (`rp_filter`) is turned off on them. The global `all` setting is lowered to 0, and every other interface keeps its previous level. On the Channel interfaces, AmneziaWG itself checks packet sources through `AllowedIPs`.

**Firewall**: iptables rules are added from `PostUp`/`PostDown`. If ufw is installed, the script adds ufw rules tagged `DoubleAWG <interface>`. It never enables or disables ufw. **Your provider's firewall** (in the hosting control panel) has to be configured by hand: open the `outway` UDP port on VPS2 and the entry interface ports on VPS1.

## Removal and reinstall

```bash
sudo /etc/amnezia/amneziawg/dawg-channel-del.sh --purge   # VPS1 first
sudo /etc/amnezia/amneziawg/dawg-channel-del.sh --purge   # then VPS2
```

`net.ipv4.ip_forward` stays enabled until the next reboot. Running `deploy-doubleawg.sh` again finds and removes the previous installation on both nodes by itself, but that also removes every client, and new keys are generated.

## Troubleshooting

```bash
sudo awg show                                   # handshakes and counters
sudo /etc/amnezia/amneziawg/dawg-entry.sh split-status                 # VPS1
ip rule; ip route show table 7101 | grep -v throw
sudo iptables -vnL FORWARD | head -20
sudo tcpdump -ni gate1 -c 20                    # what arrives from clients
```

| Symptom | Where to look |
|---|---|
| No handshake | port closed in the provider's firewall, mismatched keys or obfuscation parameters, a 3.x config on a client that doesn't support it |
| Handshake works, but the server's `received` barely grows | `S3`/`S4`/`H3`/`H4` differ between client and server. Re-import the whole client config |
| Russian sites load, others don't | the Channel: `awg show inway` / `awg show outway`, and `ip route get <IP> from <client> iif outway` on VPS2 |
| No connection in `connect` mode | the client must accept inbound UDP on its `ListenPort` (firewall or port forwarding on the client side) |

## Disclaimer

This script changes network routing and firewall rules on your servers. Test it in a non-production environment before using it on servers you depend on, and make sure you follow the laws that apply to you.
