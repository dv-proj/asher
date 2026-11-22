# do-first — first-time VPS setup

[RUS](README.md) [ENG](README-EN.md)

`do-first.sh` sets up a fresh headless Ubuntu or Debian server: updates the system, creates a user, locks down SSH, enables the firewall and automatic updates. It runs on the server itself as root.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/dv-proj/asher/main/do-first/do-first.sh | sudo bash
```

The script asks its questions through the terminal (`/dev/tty`), so piping works. To read it first:

```bash
curl -fsSLO https://raw.githubusercontent.com/dv-proj/asher/main/do-first/do-first.sh
sudo bash do-first.sh
```

Unattended, with answers preset:

```bash
curl -fsSL https://raw.githubusercontent.com/dv-proj/asher/main/do-first/do-first.sh | sudo NEW_USER=admin USER_PASSWORD=... SSH_PUBKEY=github:myname TIMEZONE=Europe/Moscow bash -s -- --yes
```

## Steps

| Step | What it does |
|---|---|
| `preflight` | checks root, OS, network, current SSH settings |
| `apt_upgrade` | `apt update/upgrade`; reboot if needed |
| `packages` | base utilities (list in `BASE_PACKAGES`) |
| `user` | user with sudo, the password is always asked for a new user |
| `ssh_key` | key(s) in `authorized_keys`: a line, `github:<user>` or a URL |
| `ssh_harden` | disables password login; optionally root login and port change |
| `firewall` | ufw: deny incoming, rate-limited SSH, extra ports |
| `fail2ban` | protects sshd from brute force |
| `unattended` | automatic security updates, optional auto-reboot |
| `timezone_time` | timezone and time synchronization |
| `hostname` | hostname, `/etc/hosts`, cloud-init |
| `locale` | optional |
| `journald_logs` | journal size limit, logrotate |
| `swap` | swap file if there is no swap (size is asked, default 512M) |
| `sysctl` | safe kernel parameters (`ip_forward` and `rp_filter` are left alone — VPN is configured separately) |
| `disable_extra` | disables unneeded Ubuntu services (snapd etc.) |
| `docker` | optional, from the official repository |
| `cleanup` | `autoremove`, `clean`, reboot check |

List the steps and their status: `do-first.sh --list`.

## SSH safety

- Password login is disabled only if the user has a valid key, sudo works and `authorized_keys` permissions are correct. Otherwise the script warns and skips the change.
- The config goes to `/etc/ssh/sshd_config.d/99-do-first.conf` and is checked with `sshd -t` and `sshd -T`; on failure the backups are restored.
- When the port changes, the new one is opened in ufw first. The old port stays open until you have tested the login.
- **Do not close your current session until you have logged in as the new user in a second one.**

## Resume and reboot

State lives in `/var/lib/do-first/`: completed steps (by ID) and saved answers (mode 600). A rerun continues from the first unfinished step and asks nothing again. If a reboot is needed, the script installs a one-shot systemd unit `do-first-resume.service` and setup continues after boot. Log: `/var/log/do-first.log`.

## Options

| Option | Meaning |
|---|---|
| `--yes`, `-y` | accept defaults |
| `--dry-run` | show actions, change nothing |
| `--list` | show steps and status |
| `--reset` | forget state |
| `--help` | help |

Environment variables (answers to the questions):

- user and SSH: `NEW_USER`, `USER_PASSWORD`, `SET_PASSWORD` (existing user only), `SSH_PUBKEY`, `DISABLE_PASSWORD_AUTH`, `DISABLE_ROOT_SSH`, `SSH_PORT`
- firewall and fail2ban: `UFW_EXTRA_PORTS`, `IGNORE_IPS`
- automatic updates: `AUTO_REBOOT`, `AUTO_REBOOT_TIME`, `UPGRADE_UPDATES`
- system: `TIMEZONE`, `HOSTNAME_NEW`, `CONFIGURE_LOCALE`, `LOCALE`, `JOURNAL_MAX`, `SWAP_SIZE`, `DISABLE_EXTRA`, `INSTALL_DOCKER`
- other: `ALLOW_REBOOT`, `BASE_PACKAGES`, `SKIP_STEPS`, `SCRIPT_URL`

## Adding your own step

Write a `step_<id>` function and insert `<id>` into the `STEPS` array where you want it. Completed steps are tracked by ID, so inserting in the middle does not break the state. See the comment next to the step registry in the script.

## Limitations

- Docker publishes ports bypassing ufw.
- The script was checked for syntax and in `--dry-run` mode only; try it on a test machine before using it on a real one.

## Disclaimer

The script changes SSH and firewall settings. Test it on a throwaway machine before running it on a production one.
