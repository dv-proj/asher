# asher

[RUS](README.md) [ENG](README-EN.md)

A collection of ready-made shell scripts for quickly setting up and deploying environments on Ubuntu/Debian. Each script lives in its own folder together with its documentation and runs with a single command.

## Projects

| Folder | Description |
|---|---|
| [double-awg](double-awg/README-EN.md) | **DoubleAWG** — a cascaded VPN across two VPS using [AmneziaWG](https://docs.amnezia.org/documentation/amnezia-wg/) (kernel module). Clients connect to the first server, traffic goes through an IPv6 tunnel to the second one and leaves to the internet from there. It has a kill-switch and split routing for Russian IPs. The script runs on your machine and configures both servers over SSH. |

### double-awg: quick start

```bash
curl -fsSL https://raw.githubusercontent.com/dv-proj/asher/main/double-awg/deploy-doubleawg.sh | bash
```

Requirements, options and server management are described in the [project documentation](double-awg/README-EN.md).

## Principles

- One script, one task, no external dependencies beyond standard utilities.
- Before changing anything, the script shows a summary and asks for confirmation.
- Secrets (keys, passwords) are stored only locally, in a folder with `700` permissions.

## License

See [LICENSE](LICENSE).
