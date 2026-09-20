# gateway-api-crds

Installs the Kubernetes **Gateway API CRDs, standard channel v1.5.1**, from the
vendored file `crds/standard-install-v1.5.1.yaml`, so nothing is fetched from
GitHub at apply time.

**Resources:** one `kubectl_manifest` per document in the file:

- CRDs: GatewayClass, Gateway, HTTPRoute, GRPCRoute, ReferenceGrant, TLSRoute,
  ListenerSet, BackendTLSPolicy
- `ValidatingAdmissionPolicy` and `ValidatingAdmissionPolicyBinding`, both named
  `safe-upgrades.gateway.networking.k8s.io`. Upstream ships these to block
  unsafe CRD changes, such as downgrading to an older bundle in place.

**Inputs:** none. **Output:** `applied_resource_keys`, the list of
`Kind/name` keys applied, so a missing CRD is visible in the Terraform output.

## How the file is split

- The YAML is split on `---`.
- The license header (a comment-only chunk) is dropped; `yamldecode` errors on it.
- Each document is keyed by `Kind/name`, not just name, because the two
  `safe-upgrades` objects share a name.

## Lab-specific notes

- Applied **early and alone** by `bootstrap-crds` / `make crds`
  (`-target=module.gateway_api_crds`), before Cilium.
- **Cilium 1.18.1 doesn't support these CRDs.** Its operator requests TLSRoute
  `v1alpha2`, which v1.5.1 no longer serves (TLSRoute is `v1` only here). With
  `gatewayAPI.enabled=true` the operator crash-loops and the cluster has no
  networking. Both prod and the lab therefore run Cilium with Gateway API
  **off**; the CRDs are installed but unused.
- **To bump:** drop a newer `standard-install-vX.Y.Z.yaml` in `crds/` and point
  `local.gateway_api_manifest` at it. Downgrades will likely be refused by the
  `safe-upgrades` admission policy.
