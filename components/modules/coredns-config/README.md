# coredns-config

Replaces the Corefiles of the cluster's two DNS layers, so pods can resolve
homelab names (`*.example.com`) through the internal resolver, exactly as in prod.

```
pod → NodeLocalDNS (169.254.25.10, on every node) → CoreDNS (10.233.0.3) → upstream
```

## Resources

Both are `kubectl_manifest` with **server-side apply + `force_conflicts`**, so
they take over the ConfigMaps Kubespray created. The Terraform plan shows them
as "will be created"; that's expected.

### ConfigMap `kube-system/coredns`

| Zone | Behaviour |
|---|---|
| `.:53` | serves `cluster.local` (and reverse zones) from Kubernetes; forwards everything else to `upstream_dns` then `8.8.8.8`; cache 30 s; Prometheus metrics on `:9153` |
| `example.com:53` (`internal_domain`) | forwards only to `upstream_dns`, never to 8.8.8.8 |

### ConfigMap `kube-system/nodelocaldns`

The node-local cache Kubespray deploys, bound to `169.254.25.10`:

| Zone | Forwards to |
|---|---|
| `cluster.local`, `in-addr.arpa`, `ip6.arpa` | CoreDNS at `coredns_ip`, over TCP |
| `example.com` | `upstream_dns` |
| `.` (everything else) | `upstream_dns`, `8.8.8.8` |

Metrics on `:9253`, health on `169.254.25.10:9254`.

## Inputs

| Variable | Default | Notes |
|---|---|---|
| `upstream_dns` | `192.0.2.168` | homelab resolver (Pi-hole) |
| `internal_domain` | `example.com` | |
| `coredns_ip` | `10.233.0.3` | **derived from the service CIDR**: Kubespray gives CoreDNS the 3rd address of `kube_service_addresses` (`10.233.0.0/18`). Change the CIDR, change this |

**Outputs:** `upstream_dns`, `internal_domain`.

## Watch out

- If `192.0.2.168` is unreachable from the venue, `example.com` names fail but
  public names still resolve via `8.8.8.8`.
- Both caches `reload` automatically after a ConfigMap change; no restart needed.
- Destroying this module deletes the ConfigMaps, which breaks cluster DNS
  until Kubespray or a re-apply recreates them. Normally it only happens with
  `make down`, where it doesn't matter.
