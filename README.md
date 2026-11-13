# Mac Mini Server Setup

Scripts that turn a fresh Apple Silicon Mac mini into a home media server. You run one script on your own Mac to build a setup package. Then you run one on the Mac mini to set up the system, and one more to install the apps. Every script is idempotent, so you can run it again after a failure.

**Documentation: <https://smartwatermelon.github.io/mac-server-setup/>**

## What it sets up

- Plex Media Server, reading media from a NAS over NFS.
- A separate `operator` account that logs in automatically, so the services come back after a power cut.
- Optional: Transmission in a Podman container, with all of its traffic forced through a PIA VPN.
- Optional: Catch for RSS feeds, rclone for Dropbox, and FileBot to rename downloads and file them in the Plex library.
- Optional: a Caddy dashboard, with remote access through Cloudflare Tunnel and Cloudflare Access.
- Optional: watchdogs that send email when Plex, the VPN port forwarding or the tunnel break.

Secrets come from 1Password on your own Mac. The Mac mini never needs a 1Password session.

## Start here

- New install: the [get-started tutorial](https://smartwatermelon.github.io/mac-server-setup/get-started/), eight pages from a spare Mac mini to the first play in Plex.
- Which parts you need, and what you can leave out or replace: the [stack matrix](https://smartwatermelon.github.io/mac-server-setup/reference/stack-matrix/).

The site source is in [`docs/`](docs/index.md). The `docs/plans/` and `docs/archive/` folders hold design history.

## Tests

Tests use [BATS](https://github.com/bats-core/bats-core). Run the file for the code you change:

```bash
bats tests/<name>.bats
```

CI runs the full suite (`bats --recursive tests`) on every pull request and on pushes to `main`. It also runs a strict docs build and a link check.

Lint shell scripts with:

```bash
shellcheck -S info <script>
shfmt -d -i 2 -ci -bn <script>
```

## Contributing

Scripts must be idempotent. In scripts, use these helpers:

- `log()` and `show_log()` for output.
- `collect_error()` for problems that block setup.
- `collect_warning()` for optional parts that are missing.
- `set_section()`, so that each message says where it came from.

Update the docs when you change a config key or a behavior. `shellcheck` must pass with no findings.

## License

MIT. See [LICENSE](LICENSE.md).
