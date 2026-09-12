terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

# Gateway API CRDs (Standard channel v1.5.1: GatewayClass, Gateway, HTTPRoute,
# GRPCRoute, ReferenceGrant, TLSRoute, ListenerSet, BackendTLSPolicy) --
# vendored rather than fetched live at apply-time, so applies stay
# reproducible even if upstream releases move or GitHub is unreachable.
# Bump by replacing crds/standard-install-v*.yaml with a newer release.
locals {
  gateway_api_manifest = file("${path.module}/crds/standard-install-v1.5.1.yaml")
  gateway_api_raw_docs = [
    for doc in split("\n---\n", local.gateway_api_manifest) : trimspace(doc)
    if trimspace(doc) != "" && trimspace(doc) != "---"
  ]
  # The file's leading license header ends up as its own chunk (everything
  # before the first real "---"). yamldecode errors outright on a
  # comment-only document ("missing start of document") rather than
  # returning null, so it has to be filtered out by matching raw text --
  # calling yamldecode on it to test would itself be the error. This keeps
  # any doc with at least one non-comment, non-blank line.
  gateway_api_real_docs = [
    for doc in local.gateway_api_raw_docs : doc
    if length(regexall("(?m)^[^#\n].*", doc)) > 0
  ]

  # Keyed on kind+name, not name alone -- the manifest carries a
  # ValidatingAdmissionPolicy and a ValidatingAdmissionPolicyBinding that
  # share the same name ("safe-upgrades..."), which would collide otherwise.
  gateway_api_docs = {
    for doc in local.gateway_api_real_docs : "${yamldecode(doc).kind}/${yamldecode(doc).metadata.name}" => doc
  }
}

resource "kubectl_manifest" "gateway_api" {
  for_each  = local.gateway_api_docs
  yaml_body = each.value
}
