# Prerequisites

Things to have in place before deploying the Omni half of this starter.

## Infrastructure

### Proxmox VE host
- **Proxmox VE 8.x** installed and accessible
- **API access** on port `8006` (default)
- **Storage pool** with at least ~600 GB free (3 CPs × 60 GB + 3 workers × 200 GB)
- **A user with VM management permissions**. `root@pam` is fine for testing;
  for production use a dedicated `omni@pve` user — see the bottom of
  `omni/proxmox-provider/config.yaml.example` for the role-grant commands.
- **Network bridge** that VMs can attach to (default: `vmbr0`) with DHCP, or
  a DHCP server that hands out IPs in the VM range.

### Linux host for Omni server
- **Any Docker-capable Linux distro** (Ubuntu 22.04+, Debian 12+, Arch, Fedora,
  etc.). Doesn't need to be a beefy box — Omni itself is light.
- **≥ 2 GB RAM, ≥ 20 GB free disk** for etcd + SQLite stores
- **Reachable from your VMs over the LAN** — Talos nodes will use SideroLink
  (WireGuard) to call back to Omni, so the host's LAN IP needs to be stable
- **Static IP or DHCP reservation** is strongly recommended

> The Omni host can be the same machine you run `kubectl` from, or a small VM
> on the Proxmox host itself, or a separate physical box. There's no
> co-location requirement.

## Software on the Omni host

### Docker + Docker Compose v2
```bash
# One-line installer for any major distro
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
# Log out / back in for group membership to apply
docker compose version  # should print v2.x
```

### Certbot (for the Omni UI's TLS cert)
```bash
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/bin/certbot   # only if /usr/bin/certbot is missing
```
The included `omni/scripts/setup-ssl.sh` automates everything if your domain
is on Cloudflare. If not, generate a cert via any other ACME route and point
`omni.env`'s `TLS_CERT` / `TLS_KEY` at the resulting files.

### GPG (for etcd-at-rest encryption)
Pre-installed on most distros; verify with `gpg --version`. The included
`omni/scripts/setup-gpg.sh` walks you through key generation.

### `omnictl` (for talking to Omni from your laptop)
Download for your platform from
<https://github.com/siderolabs/omni/releases>. The starter expects this in
your `$PATH` so `omni/bootstrap.sh` can apply machine classes and the
cluster template.

## Domain and DNS

You need a domain name you control. **Internal-only is fine** — the Omni UI
doesn't need to be publicly reachable.

- **A record**: `omni.<your-domain>` → the LAN IP of your Omni host
- **TLS cert**: most homelabs use Let's Encrypt with the **DNS-01** challenge
  (works for internal-only domains because DNS-01 doesn't require a public
  HTTP server). Cloudflare is the easiest provider; the included script
  automates it.

If you don't host your domain on Cloudflare:
- **acme.sh** supports dozens of DNS providers
- **Caddy / Step CA** for an internal certificate authority
- **Self-signed cert** if you don't mind clicking through browser warnings

## Authentication provider

Omni delegates user authentication to an external provider. Pick one:

### Auth0 (recommended for homelab)
- Free tier, no credit card required
- Social login support (Google, GitHub) means you can sign in with an existing
  account
- Setup: <https://auth0.com/> → create a "Single Page Application" → copy the
  Domain and Client ID into `omni.env`

### SAML (Entra ID, Okta, Keycloak, etc.)
Drop the SSO URL into the `AUTH=--auth-saml-...` line in `omni.env`.

### OIDC (any compliant provider)
Same as SAML but for OIDC; `--auth-oidc-...` flags.

The **email** of your initial admin user (`INITIAL_USER_EMAILS` in
`omni.env`) must match the email associated with your auth provider account.

## Network ports

### On the Omni host
| Port | Direction | Purpose |
|---|---|---|
| `443/tcp` | Inbound | HTTPS API + Web UI |
| `8090/tcp` | Inbound from Talos nodes | Machine API (gRPC) |
| `8100/tcp` | Inbound | Kubernetes proxy |
| `50180/udp` | Inbound from Talos nodes | SideroLink (WireGuard) |

> If your Linux host has UFW or firewalld enabled by default, allow these
> ports inbound. Outbound from the Omni host needs to reach Cloudflare /
> Auth0 / your DNS provider during cert setup, but no specific firewall
> rules are usually needed.

### Outbound from the Proxmox provider
- HTTPS to your Omni API (`OMNI_API_ENDPOINT` in
  `omni/proxmox-provider/.env`)
- HTTPS to your Proxmox API (port 8006)

## Pre-flight checklist

Before running `docker compose up -d` for Omni:

- [ ] Proxmox host accessible, API token created
- [ ] Linux host with Docker + Docker Compose
- [ ] Domain DNS A record pointing at the Omni host
- [ ] DNS provider API token (for cert generation)
- [ ] Authentication provider chosen and admin email registered
- [ ] Ports 443, 8090, 8100, 50180/udp open inbound on the Omni host
- [ ] `omnictl` installed locally
- [ ] Account UUID generated (`uuidgen`)
- [ ] Storage pool name chosen on Proxmox (you'll fill it into the
      `__REPLACE_ME_PROXMOX_STORAGE_POOL__` placeholder)

When all boxes are ticked, proceed to `omni/README.md` for the bring-up
sequence.
