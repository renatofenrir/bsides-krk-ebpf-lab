terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
  }
}

resource "kubectl_manifest" "coredns_configmap" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "coredns"
      namespace = "kube-system"
      labels = {
        "addonmanager.kubernetes.io/mode" = "EnsureExists"
      }
    }
    data = {
      Corefile = <<-EOT
        .:53 {
            errors {
            }
            health {
                lameduck 5s
            }
            ready
            kubernetes cluster.local in-addr.arpa ip6.arpa {
              pods insecure
              fallthrough in-addr.arpa ip6.arpa
            }
            prometheus :9153
            forward . ${var.upstream_dns} 8.8.8.8 {
              prefer_udp
              max_concurrent 1000
            }
            cache 30
            loop
            reload
            loadbalance
        }
        ${var.internal_domain}:53 {
            errors
            cache 30
            forward . ${var.upstream_dns}
        }
      EOT
    }
  })

  force_conflicts   = true
  server_side_apply = true
}

resource "kubectl_manifest" "nodelocaldns_configmap" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "nodelocaldns"
      namespace = "kube-system"
      labels = {
        "addonmanager.kubernetes.io/mode" = "EnsureExists"
      }
    }
    data = {
      Corefile = <<-EOT
        cluster.local:53 {
            errors
            cache {
                success 9984 30
                denial 9984 1
            }
            reload
            loop
            bind 169.254.25.10
            forward . ${var.coredns_ip} {
                force_tcp
            }
            prometheus :9253
            health 169.254.25.10:9254
        }
        in-addr.arpa:53 {
            errors
            cache 30
            reload
            loop
            bind 169.254.25.10
            forward . ${var.coredns_ip} {
                force_tcp
            }
            prometheus :9253
        }
        ip6.arpa:53 {
            errors
            cache 30
            reload
            loop
            bind 169.254.25.10
            forward . ${var.coredns_ip} {
                force_tcp
            }
            prometheus :9253
        }
        ${var.internal_domain}:53 {
            errors
            cache {
                success 9984 30
                denial 9984 1
            }
            reload
            loop
            bind 169.254.25.10
            forward . ${var.upstream_dns}
            prometheus :9253
        }
        .:53 {
            errors
            cache {
                success 9984 30
                denial 9984 1
            }
            reload
            loop
            bind 169.254.25.10
            forward . ${var.upstream_dns} 8.8.8.8
            prometheus :9253
        }
      EOT
    }
  })

  force_conflicts   = true
  server_side_apply = true
}