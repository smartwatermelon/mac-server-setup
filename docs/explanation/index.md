# Explanation

These pages say why the server is built the way it is. They describe the design decisions, the trade-offs, and the constraints from macOS, Homebrew and Cloudflare that shaped them. They do not give steps. For steps, use the [get-started tutorial](../get-started/index.md) and the component pages under `docs/components/`.

## Pages

- [Architecture](architecture.md): the three setup phases, the `admin` and `operator` accounts, LaunchAgents and LaunchDaemons, and why Transmission runs in Podman behind a VPN.
- [TLS strategy](tls-strategy.md): Caddy's internal CA for LAN names, DNS-01 with Cloudflare for the public name, and how the Cloudflare token reaches Caddy.
- [Credential chain](credential-chain.md): how secrets move from 1Password to the services, and why long-running services keep them off the command line.
- [Storage and VirtioFS](storage-virtiofs.md): the NAS over NFS, VirtioFS into the Podman VM, the disabled incomplete directory, and the macOS privacy grants.
- [Tunnel security layers](tunnel-security-layers.md): Cloudflare Tunnel and Access, and the checks on the server that still hold if one layer fails.

## How to read them

Each page states a constraint, then the design that follows from it. Where the code and an older document disagree, these pages follow the code and link to it on GitHub. Dates in the pages mark when a behavior was observed on a real server. They are not release dates.
