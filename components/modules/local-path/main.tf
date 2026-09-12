terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
  }
}

resource "helm_release" "local_path_provisioner" {
  name             = "local-path-provisioner"
  repository       = "https://charts.containeroo.ch"
  chart            = "local-path-provisioner"
  version          = var.chart_version
  namespace        = "local-path-provisioner"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      storageClass = {
        name        = var.storage_class_name
        defaultPath = var.default_path
        pathPattern = var.path_pattern
        reclaimPolicy = "Retain"
      }

      nodePathMap = [
        {
          node  = "DEFAULT_PATH_FOR_NON_LISTED_NODES"
          paths = [var.default_path]
        }
      ]

      affinity = {
        nodeAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [
              {
                matchExpressions = [
                  {
                    key      = var.node_label_key
                    operator = "In"
                    values   = var.node_label_values
                  }
                ]
              }
            ]
          }
        }
      }
    })
  ]
}

# resource "kubernetes_storage_class" "local_path" {
#   depends_on = [helm_release.local_path_provisioner]

#   metadata {
#     name = var.storage_class_name
#     annotations = {
#       "storageclass.kubernetes.io/is-default-class" = tostring(var.is_default)
#     }
#   }

#   storage_provisioner    = "cluster.local/local-path-provisioner"
#   reclaim_policy         = "Retain"
#   volume_binding_mode    = "WaitForFirstConsumer"
#   allow_volume_expansion = true
# }
