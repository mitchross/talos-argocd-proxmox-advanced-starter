#!/usr/bin/env python3
"""Validate HTTPRoute public-DNS controls and named Service backend ports."""

import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("pyyaml required: pip3 install pyyaml\n")
    sys.exit(2)


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: validate-gateway-contracts.py <rendered.yaml>\n")
        return 2

    yaml.SafeLoader.add_constructor(
        "tag:yaml.org,2002:value",
        lambda loader, node: loader.construct_scalar(node),
    )
    with open(sys.argv[1]) as manifests:
        docs = [d for d in yaml.safe_load_all(manifests) if isinstance(d, dict)]

    services = {}
    for doc in docs:
        if doc.get("kind") == "Service":
            metadata = doc.get("metadata") or {}
            services[(metadata.get("namespace", "default"), metadata.get("name"))] = doc

    errors = []
    route_count = 0
    external_count = 0
    for route in docs:
        if route.get("kind") != "HTTPRoute":
            continue
        route_count += 1
        metadata = route.get("metadata") or {}
        namespace = metadata.get("namespace", "default")
        route_name = f"{namespace}/{metadata.get('name')}"

        for parent in (route.get("spec") or {}).get("parentRefs") or []:
            if parent.get("name") != "gateway-external":
                continue
            external_count += 1
            if (metadata.get("labels") or {}).get("external-dns") != "true":
                errors.append(f"{route_name}: missing external-dns=true label")
            if not (metadata.get("annotations") or {}).get(
                "external-dns.alpha.kubernetes.io/target"
            ):
                errors.append(f"{route_name}: missing ExternalDNS target annotation")
            if parent.get("sectionName") != "https":
                errors.append(f"{route_name}: external parentRef must select sectionName=https")

        for rule in (route.get("spec") or {}).get("rules") or []:
            for backend in rule.get("backendRefs") or []:
                if backend.get("kind", "Service") != "Service":
                    continue
                service_namespace = backend.get("namespace", namespace)
                service = services.get((service_namespace, backend.get("name")))
                if service is None:
                    continue
                matching_ports = [
                    port
                    for port in (service.get("spec") or {}).get("ports") or []
                    if port.get("port") == backend.get("port")
                ]
                if matching_ports and not all(port.get("name") for port in matching_ports):
                    errors.append(
                        f"{route_name}: backend {service_namespace}/"
                        f"{backend.get('name')} port {backend.get('port')} is unnamed"
                    )

    for error in errors:
        print(f"FAIL {error}")
    if errors:
        return 1
    print(
        f"Gateway contracts OK: {route_count} HTTPRoutes, "
        f"{external_count} external parentRefs."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
