# Omni / Proxmox provider / Talos troubleshooting

Common failures during the provisioning half of this starter, with fixes.

> If your problem is on the *Kubernetes* side (after `kubectl get nodes`
> works but ArgoCD apps aren't syncing, etc.), see
> `docs/getting-started.md` and `docs/architecture.md` in the repo root.

---

## Omni server

### Cannot reach the Omni UI in a browser

```bash
# Container running?
cd omni/omni && docker compose ps

# Recent logs
docker compose logs omni | tail -50

# Is the host actually listening on 443?
sudo ss -tlnp | grep :443

# Does DNS resolve?
nslookup omni.<your-domain>

# Is the cert valid?
curl -k https://omni.<your-domain>
```

Common fixes:

- **Container not running**: `docker compose up -d` from `omni/omni/`
- **Port 443 already in use** (often nginx, Caddy, or another container):
  `sudo lsof -i :443` to find the offender. Either stop it or change
  `BIND_ADDR` in `omni.env` to a different port and re-run the cert setup
  script with that port.
- **Host firewall**: `sudo ufw allow 443/tcp` (etc., per the table in
  `PREREQUISITES.md`)
- **Wrong cert paths in `omni.env`**:
  `ls -la /etc/letsencrypt/live/omni.<your-domain>/` — fullchain.pem and
  privkey.pem must both exist.

### Omni container exits immediately

```bash
docker compose logs omni
```

Look for the failure pattern:

- **`permission denied` reading etcd or sqlite paths**:
  ```bash
  sudo chown -R 1000:1000 /etc/etcd /etc/omni/sqlite
  sudo chmod -R 700 /etc/etcd /etc/omni/sqlite
  ```
- **`failed to decrypt`** — the GPG key in `ETCD_ENCRYPTION_KEY` is wrong or
  was generated for a different email. Re-run `scripts/setup-gpg.sh`.
- **`certificate has expired` or `signed by unknown authority`** — the
  Let's Encrypt cert needs renewing or the cert path is pointing at the
  wrong file. `certbot certificates` lists what you have.

### Authentication fails (Auth0)

- The **callback URL** in your Auth0 application settings must match
  exactly: `https://omni.<your-domain>:443/oidc/callback` (with the `:443`
  even though that's the default HTTPS port).
- The `AUTH0_DOMAIN` value must NOT include the `https://` prefix —
  just `your-tenant.us.auth0.com`.
- The email under `INITIAL_USER_EMAILS` in `omni.env` must match the
  email Auth0 has on file for the user you're logging in as.

---

## Talos nodes won't connect to Omni

Symptom: nodes are visible in Proxmox console but never appear in the Omni
UI under "Machines".

```bash
# From the Talos node (use the IP you see in Proxmox)
talosctl -n <node-ip> get links
talosctl -n <node-ip> get members
```

Common fixes:

- **WireGuard advertised address is wrong**:
  `SIDEROLINK_WIREGUARD_ADVERTISED_ADDR` in `omni.env` must be the LAN IP
  of the Omni host followed by `:50180`. Hostnames don't work here — Talos
  needs an IP for the WireGuard handshake.
- **UDP port 50180 blocked**: Test with
  `nc -uvz <omni-host-ip> 50180` from the Proxmox host (or any LAN host).
- **No DHCP**: VMs need an IP. Check Proxmox bridge config; check your
  router's DHCP scope hasn't run dry.

---

## Proxmox provider won't start

```bash
cd omni/proxmox-provider
docker compose logs omni-infra-provider-proxmox | tail -50
```

Failure patterns:

- **`connection refused` to Omni**: `OMNI_API_ENDPOINT` in `.env` must be
  the full URL **with trailing slash**:
  `https://omni.<your-domain>/`
- **`connection refused` to Proxmox**: `proxmox.url` in `config.yaml` is
  wrong or Proxmox API is firewalled. Test with
  `curl -k https://<proxmox-host>:8006/api2/json/version`.
- **`401 unauthorized`**: API token is wrong, or "Privilege Separation" was
  left enabled when you created the token (uncheck it; the token then
  inherits the user's full role).
- **"infrastructure provider key is invalid"**: you used a *service account*
  key instead of an *infrastructure provider* key. Regenerate from
  `Settings → Infrastructure Providers → Create Provider` in the Omni UI.

---

## VMs not being created in Proxmox

After `omni/bootstrap.sh` runs, you should see VMs appear in the Proxmox UI
within ~1 minute. If they don't:

```bash
docker compose logs -f omni-infra-provider-proxmox
```

- **Storage selector returned no results** —
  `name == "__REPLACE_ME_PROXMOX_STORAGE_POOL__"` was never substituted, or
  the pool name doesn't match. List your pools:
  ```bash
  pvesh get /storage   # on the Proxmox host
  ```
  Update `omni/machine-classes/control-plane.yaml` and `worker.yaml` to use
  the correct pool name, then re-apply:
  ```bash
  omnictl apply -f omni/machine-classes/control-plane.yaml
  omnictl apply -f omni/machine-classes/worker.yaml
  ```
- **`Permission denied`** — your API token's user lacks
  `VM.Allocate`. Either use `root@pam` for testing or grant
  `PVEVMAdmin` (see the comments at the bottom of `config.yaml.example`).
- **`Storage full`** —
  ```bash
  pvesh get /storage --enabled 1
  ```
  Free space or pick a different pool.

---

## Cluster bootstraps part-way then stalls — Talos 1.13 install-disk

**Most common newbie failure** on Talos 1.13: VMs boot fine and show up in
Omni, but they get stuck in "Installing" or, worse, the cluster
half-bootstraps and hangs in "Bootstrapping" forever.

The smoking-gun diagnosis is to look at one of the control-plane nodes in
Omni:

```
stage = 7 (UPGRADING)
configuptodate = false
```

…cycling indefinitely with no error. The LifecycleService API in Talos
1.13+ requires an explicit `machine.install.disk`, and without it the
upgrade silently never converges.

**Fix**: this starter ships the patch in
`omni/cluster-template/cluster-template.yaml`:

```yaml
- name: install-disk
  inline:
    machine:
      install:
        disk: /dev/sda
```

If you see this symptom, verify the patch is present in the template you
synced. `/dev/sda` is correct for the default Proxmox provider config
(virtio-scsi-single + scsi0). If you customized to NVMe passthrough, swap
to `/dev/nvme0n1` and re-sync the template.

---

## Cluster bootstraps but `kubectl get nodes` is empty

The Omni UI shows the cluster healthy, but `kubectl get nodes` returns
"the server has asked for the client to provide credentials" or shows no
nodes. Almost always the kubeconfig is stale — pull a fresh one:

```bash
omnictl kubeconfig --cluster homelab --force
kubectl get nodes
```

If you're using OIDC kubeconfig (the default) and getting browser-popup
fatigue, swap to a service-account token-based kubeconfig:

```bash
omnictl serviceaccount create homelab-sa --use-user-role
# Save OMNI_SERVICE_ACCOUNT_KEY printed to stdout — shown only once!

OMNI_SERVICE_ACCOUNT_KEY="<key>" \
omnictl kubeconfig --cluster homelab --service-account --user homelab-sa --force
```

---

## Where to get more help

- **Sidero Slack** — `#omni` and `#talos` channels at
  <https://slack.dev.talos-systems.io/>
- **Omni issues** — <https://github.com/siderolabs/omni/issues>
- **Talos issues** — <https://github.com/siderolabs/talos/issues>
- **Proxmox provider issues** — <https://github.com/siderolabs/omni-infra-provider-proxmox/issues>
- **Talos docs** — <https://docs.siderolabs.com/talos/>

When opening an issue, include:
- Omni version (`docker inspect omni | grep image`)
- Talos version (`talosctl version --nodes <node-ip>`)
- Provider version (`docker inspect omni-infra-provider-proxmox | grep image`)
- Sanitized `omni.env` and `config.yaml`
- Last 100 lines of `docker compose logs` for both containers
