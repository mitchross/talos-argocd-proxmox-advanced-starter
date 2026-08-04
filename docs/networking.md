# Networking: one private path, one public path

The starter uses Cilium Gateway API exclusively. It deliberately demonstrates
two DNS and routing paths without exposing every service publicly.

| Example | DNS writer | Gateway | Reachability |
|---|---|---|---|
| nginx, Argo CD, Longhorn, Grafana | ExternalDNS RFC2136 | `gateway-internal-technitium` | LAN only |
| karakeep, Gitea | ExternalDNS Cloudflare | `gateway-external` -> cloudflared | public |

## Address plan

Choose a Cilium LoadBalancer pool that does not overlap DHCP. The example uses
`192.168.10.32/27` and pins the private Gateway to `192.168.10.52`. Update both
with `scripts/adapt-to-your-cluster.sh`.

The public Gateway does not need a LAN address. cloudflared reaches its
in-cluster Service and Cloudflare DNS points public hostnames at the tunnel.

## Technitium setup

Technitium is an external prerequisite, not a pod in this repository.

### 1. Create the split-horizon zone

In **Zones**, create a **Conditional Forwarder** zone for the same domain used
publicly in Cloudflare. This lets private records override public names while
unknown names continue to the upstream resolver. A Primary zone is also
possible, but then Technitium is authoritative for the entire zone and must
contain every public record too; otherwise private clients receive `NXDOMAIN`
for names that exist only in Cloudflare.

### 2. Create the TSIG identity

1. Open **Settings -> TSIG** in the Technitium web console.
2. Add a key such as `externaldns-vanillax` using `hmac-sha256`.
3. Let Technitium generate the shared secret, then save the key.
4. Copy the generated value directly into the 1Password item
   `external-dns-technitium-vanillax`, field `tsig-secret`.

Technitium displays the TSIG secret in Base64, which is exactly what
ExternalDNS expects. Do not decode it, wrap it in another layer of Base64, put
it in Git, or paste it into a shell command. The `ExternalSecret` creates the
Kubernetes Secret from 1Password.

### 3. Authorize updates and record discovery

Open the zone, choose **Options -> Zone Options**, and configure:

| Option | Starter setting |
|---|---|
| Query Access | Allow, or the narrowest LAN ACL that serves your clients |
| Dynamic Updates (RFC2136) | Allow with a TSIG security policy |
| TSIG key | `externaldns-vanillax` |
| Domain | `*.vanillax.xyz` after adapting the example domain |
| Record types | At least `A`, `AAAA`, `CNAME`, and `TXT` |
| Zone Transfer | Authorize only the ExternalDNS TSIG key |

The `TXT` permission is required because `registry: txt` stores ownership
records next to the DNS records. Zone transfer is deliberately restricted, but
not disabled: the current `--rfc2136-axfr` flag lets ExternalDNS list existing
records. Without AXFR, ExternalDNS behaves like `create-only` even when another
policy is configured.

> The older `--rfc2136-tsig-axfr` spelling is deprecated. This repository uses
> the current `--rfc2136-axfr` flag; the same TSIG key still authenticates the
> transfer.

### 4. Match the GitOps configuration

Set the server IP, zone, key name, and a cluster-unique TXT owner ID in
`infrastructure/controllers/external-dns/values-technitium.yaml`. Keep
`policy: upsert-only` for the first deployment so a configuration mistake
cannot delete existing records. Consider `sync` only after the generated
records and TXT ownership state have been observed.

The Technitium ExternalDNS instance watches only the labeled private Gateway.
Its Cilium policy permits TCP/UDP 53 only to the configured DNS server.

This differs intentionally from older Technitium examples: workloads use
Gateway API `HTTPRoute` rather than Ingress, the TSIG secret comes from
1Password through External Secrets rather than `kubectl create secret`, and
AXFR is authorized only for the TSIG identity instead of being open globally.

References: [archived LMNO.PK Technitium walkthrough](https://web.archive.org/web/20250320060958/https://lmno.pk/post/configuring-external-dns-technitium/)
and the [current ExternalDNS RFC2136 provider documentation](https://kubernetes-sigs.github.io/external-dns/latest/docs/tutorials/rfc2136/).

## Cloudflare setup

1. Create an API token that can edit DNS for the app zone. Store it in item
   `cert-manager-proxmox`, field `api-token`.
2. Create a Cloudflare tunnel and store its `credentials.json` in item
   `cloudflared-proxmox`, field `credentials.json`.
3. Put the tunnel name in `infrastructure/networking/cloudflared/config.yaml`.
4. Create the apex DNS route that ExternalDNS targets:
   `cloudflared tunnel route dns <tunnel-name> <domain>`.
5. Keep the wildcard tunnel ingress pointed at the external Gateway Service.
   DNS records are still opt-in per HTTPRoute.

An external HTTPRoute requires all three controls:

```yaml
metadata:
  labels:
    external-dns: "true"
  annotations:
    external-dns.alpha.kubernetes.io/target: example.com
spec:
  parentRefs:
    - name: gateway-external
      namespace: gateway
      sectionName: https
```

Private routes attach to `gateway-internal-technitium` with
`sectionName: https` and do not carry the public ExternalDNS label.

## Verify

```bash
kubectl -n gateway get gateway
kubectl -n external-dns get pods
kubectl -n external-dns logs deploy/external-dns-technitium --tail=100

dig @<technitium-ip> nginx.<domain> +short
dig @1.1.1.1 gitea.<domain> +short
curl -I https://nginx.<domain>    # from the LAN
curl -I https://gitea.<domain>    # through Cloudflare
```

Expected: the private query returns the internal Gateway IP, while the public
query resolves through Cloudflare. A Service behind an HTTPRoute must name its
HTTP port (`name: http`); unnamed ports can fail routing without an obvious
manifest error.

If no record appears, do not restart Technitium as a first response. Check the
ExternalDNS log for `REFUSED`, `NOTAUTH`, TSIG verification, or AXFR errors;
then verify the zone name, key name, Base64 secret, server clock, firewall, and
the TSIG update/transfer policies. If the log contains no desired endpoint at
all, verify the HTTPRoute parent Gateway and the Gateway label filter instead.
