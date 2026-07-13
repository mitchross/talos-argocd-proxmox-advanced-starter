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

1. Create a **Conditional Forwarder** zone for your app domain. This lets
   private records override public names while unknown names still resolve via
   Cloudflare. Do not create a Primary zone unless it contains every public
   record too.
2. Enable RFC2136 dynamic updates for the zone.
3. Create a TSIG key using `hmac-sha256` (example key name:
   `externaldns-vanillax`). Store its already-base64 value in the 1Password
   item `external-dns-technitium-vanillax`, field `tsig-secret`.
4. Set the server IP, zone, key name, and unique TXT owner ID in
   `infrastructure/controllers/external-dns/values-technitium.yaml`.

The Technitium ExternalDNS instance watches only the labeled private Gateway.
Its Cilium policy permits TCP/UDP 53 only to the configured DNS server.

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
