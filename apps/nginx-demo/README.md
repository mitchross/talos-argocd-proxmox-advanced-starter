# nginx-demo — Gateway API HTTPRoute pattern

A 30-line stateless app that exists to demonstrate exactly one
platform feature: **Gateway API + HTTPRoute attachment**, the
replacement for legacy `Ingress` resources.

After ArgoCD syncs this Application, the path to verify it's working:

```bash
kubectl get httproute -n nginx-demo
# expected: ACCEPTED=True, with one Parent showing the gateway-internal
# Gateway as the bound parent
```

Then on any LAN-attached device whose DNS resolves
`nginx.<your-domain>` to your gateway IP:

```
https://nginx.<your-domain>
```

You'll see a self-signed cert warning on the first visit (the starter's
default ClusterIssuer is `selfsigned-cluster-issuer`). Click through;
subsequent visits are silent.

---

## What's worth reading in the manifests

- **`service.yaml`** — `ports[0].name: http`. **Required** for
  HTTPRoute attachment. The Cilium Gateway controller can't resolve
  unnamed Service ports against `backendRefs[].port`, so an HTTPRoute
  pointing at an unnamed-port Service silently fails to attach (the
  HTTPRoute resource shows `Accepted=True` but no traffic flows).
  This is the single most common silent-fail in Gateway API setups.

- **`httproute.yaml`** — three pieces that bite people:
  1. `parentRefs[].sectionName: https` — without this, the route
     attaches to the implicit default listener (HTTP-only port 80)
     and HTTPS hits return 404.
  2. Cross-namespace attachment (HTTPRoute in `nginx-demo`, Gateway
     in `gateway`) works because the Gateway's
     `allowedRoutes.namespaces.from: All` permits it. If you tighten
     that, add a `ReferenceGrant`.
  3. `backendRefs[].port: 80` is the Service port (not the container
     port 8080).

- **`deployment.yaml`** — RollingUpdate strategy is fine here because
  there's no PVC. The `Recreate` requirement only applies to
  Deployments using ReadWriteOnce volumes (Longhorn) — that's the
  pattern you'll see in `apps/stateful-demo/` and any database app.

---

## To add your own stateless app

Copy this directory to `apps/<your-app>/`, edit the manifests, push.
ArgoCD's apps AppSet at Wave 6 (`apps/*` glob) picks it up
automatically. Three rules:

1. Name your Service ports (`http`, `grpc`, etc.).
2. If you need TLS termination at the Gateway, set
   `parentRefs[].sectionName: https`.
3. If you need a writable filesystem at runtime, mount an `emptyDir`
   or a PVC — don't disable `readOnlyRootFilesystem` in
   `securityContext` unless you have a reason.

For more cookbook-style guidance, see
[`docs/extending/adding-an-app.md`](../../docs/extending/adding-an-app.md).
