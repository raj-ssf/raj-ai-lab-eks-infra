resource "kubectl_manifest" "hello_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "hello"
      namespace = kubernetes_namespace.argocd.metadata[0].name
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_app_repo_url
        targetRevision = "HEAD"
        path           = "hello"
        # Phase 2 portability refactor: hello's HTTPRoute now uses
        # placeholder hostnames (hello.example.local / hello2.example.local)
        # in the apps repo. Patches inject the real var.domain hostnames
        # at sync time — same pattern as rag-service / chat-ui / etc.
        kustomize = {
          patches = [
            {
              target = {
                kind = "HTTPRoute"
                name = "hello"
              }
              patch = <<-EOT
                - op: replace
                  path: /spec/hostnames/0
                  value: hello.${var.domain}
                - op: replace
                  path: /spec/hostnames/1
                  value: hello2.${var.domain}
              EOT
            },
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "default"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "PrunePropagationPolicy=foreground",
        ]
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.argocd_app_repo,
  ]
}

resource "kubectl_manifest" "rag_service_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "rag-service"
      namespace = kubernetes_namespace.argocd.metadata[0].name
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_app_repo_url
        targetRevision = "HEAD"
        path           = "rag-service/overlays/dev"

        # Env-specific Ingress + HTTPRoute hosts injected here (NOT in
        # the public app repo). SA role binding is handled by
        # aws_eks_pod_identity_association.rag_service in
        # bedrock-irsa.tf — no annotation needed on the SA.
        # Post-Phase 12: legacy Ingress removed; only the HTTPRoute
        # hostname patch remains.
        kustomize = {
          patches = [
            {
              target = {
                kind = "HTTPRoute"
                name = "rag-service"
              }
              patch = <<-EOT
                - op: replace
                  path: /spec/hostnames/0
                  value: rag.${var.domain}
              EOT
            },
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "rag"
      }
      # Phase #35: ignore fields that argo-rollouts mutates at
      # runtime, so ArgoCD's selfHeal doesn't fight the controller.
      # RespectIgnoreDifferences=true (added to syncOptions below)
      # is what wires this through to actual sync behavior. Without
      # that flag the field is informational only on the diff view.
      ignoreDifferences = [
        {
          group = "networking.istio.io"
          kind  = "VirtualService"
          name  = "rag-service-canary-vs"
          jsonPointers = [
            "/spec/http/0/route/0/weight",
            "/spec/http/0/route/1/weight",
          ]
        },
        {
          group = ""
          kind  = "Service"
          name  = "rag-service-stable"
          jsonPointers = [
            "/spec/selector",
          ]
        },
        {
          group = ""
          kind  = "Service"
          name  = "rag-service-canary"
          jsonPointers = [
            "/spec/selector",
          ]
        },
      ]
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "PrunePropagationPolicy=foreground",
          # Phase #35: required for ignoreDifferences above to
          # actually exempt the listed fields from selfHeal.
          "RespectIgnoreDifferences=true",
        ]
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.argocd_app_repo,
  ]
}

resource "kubectl_manifest" "vllm_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "vllm"
      namespace = kubernetes_namespace.argocd.metadata[0].name
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_app_repo_url
        targetRevision = "HEAD"
        path           = "llm/overlays/dev"

        # Env-specific Ingress + HTTPRoute hosts injected here (same
        # pattern as rag-service). Pod Identity binding for the vllm
        # SA lives in model-weights.tf — no annotation patch on the
        # SA needed.
        # Post-Phase 12: legacy Ingress removed; only the HTTPRoute
        # hostname patch remains.
        kustomize = {
          patches = [
            {
              target = {
                kind = "HTTPRoute"
                name = "vllm"
              }
              patch = <<-EOT
                - op: replace
                  path: /spec/hostnames/0
                  value: llm.${var.domain}
              EOT
            },
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "llm"
      }
      # Git declares `replicas: 0` on every vllm* Deployment as the
      # steady state (cost-off). Demo/test spin-up is
      # `kubectl scale --replicas=1`. ignoreDifferences +
      # RespectIgnoreDifferences=true tells ArgoCD's selfHeal loop to
      # leave the live replica count alone — otherwise it would snap it
      # back to 0 within seconds and the GPU node would never come up.
      #
      # One entry per Deployment (the match tuple is GVK + name +
      # namespace). Grouped as:
      #   - `vllm`              — default demo path (70B AWQ on g5/g6)
      #   - `vllm-<hardware>`   — hardware-test variants (same 70B AWQ
      #                           across different GPU families); see
      #                           llm/base/deployment-variants.yaml
      #   - `vllm-<model>`      — model-test variants (different
      #                           models on their optimal hardware);
      #                           see llm/base/deployment-models.yaml
      ignoreDifferences = [
        {
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-g4dn-4gpu"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-g6e-1gpu"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-g6e-4gpu"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-p4d-8gpu"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-p5-8gpu"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-llama-8b"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-mixtral-8x7b"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-llama-vision-11b"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-llama-405b"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-deepseek-r1-70b"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          # Phase #81d: distilled 1B student (trivial-fast tier).
          # Same operator-driven scaling pattern as the other vllm-*
          # Deployments — kubectl scale up for demos, scale to 0
          # after. Without this entry ArgoCD selfHeal reverts kubectl
          # scale within ~3 sec because llm/base/deployment-models.
          # yaml hard-codes replicas: 0.
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-llama-1b-distilled"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-bge-m3"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          # bge-reranker (TEI cross-encoder, RAG completeness phase).
          # Same scale-to-zero default + manual spin-up pattern.
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-bge-reranker"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
        {
          # llama-guard-3-8b (Phase #4 content safety classifier).
          # Same scale-to-zero default; operator scales up before a
          # session that needs the safety filter active. Caught in the
          # 2026-04-29 Phase #4 activation smoke — without this entry
          # ArgoCD selfHeal reverts the manual scale-up mid-cold-start.
          group        = "apps"
          kind         = "Deployment"
          name         = "vllm-llama-guard-3-8b"
          namespace    = "llm"
          jsonPointers = ["/spec/replicas"]
        },
      ]
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "PrunePropagationPolicy=foreground",
          "RespectIgnoreDifferences=true",
        ]
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.argocd_app_repo,
  ]
}

resource "kubectl_manifest" "langgraph_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "langgraph-service"
      namespace = kubernetes_namespace.argocd.metadata[0].name
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_app_repo_url
        targetRevision = "HEAD"
        path           = "langgraph-service/overlays/dev"

        # Env-specific Ingress + HTTPRoute hosts injected here (same
        # pattern as rag-service + vllm). The hostname in the source
        # manifest is a placeholder that gets replaced per environment
        # without forking the manifest.
        kustomize = {
          patches = [
            # Post-Phase 12: legacy Ingress removed; only the HTTPRoute
            # hostname patch remains.
            {
              target = {
                kind = "HTTPRoute"
                name = "langgraph-service"
              }
              patch = <<-EOT
                - op: replace
                  path: /spec/hostnames/0
                  value: langgraph.${var.domain}
              EOT
            },
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "langgraph"
      }
      # Phase #31: ignore fields that argo-rollouts mutates at
      # runtime, so ArgoCD's selfHeal doesn't fight the controller.
      # RespectIgnoreDifferences=true (in syncOptions below) is what
      # actually wires this up — without that flag the field is
      # just informational on the diff view.
      ignoreDifferences = [
        # VirtualService route weights — mutated at every canary
        # step (setWeight 0/10/50/100 → corresponding weights on
        # the two destinations). Two pointers because the route
        # has two destinations (stable + canary).
        {
          group = "networking.istio.io"
          kind  = "VirtualService"
          name  = "langgraph-service-canary-vs"
          jsonPointers = [
            "/spec/http/0/route/0/weight",
            "/spec/http/0/route/1/weight",
          ]
        },
        # -stable / -canary Service selectors. argo-rollouts injects
        # rollouts-pod-template-hash so each Service targets only
        # the pods of its respective ReplicaSet. Without this
        # ignore, selfHeal would strip the injected label and break
        # the canary's traffic isolation.
        {
          group = ""
          kind  = "Service"
          name  = "langgraph-service-stable"
          jsonPointers = [
            "/spec/selector",
          ]
        },
        {
          group = ""
          kind  = "Service"
          name  = "langgraph-service-canary"
          jsonPointers = [
            "/spec/selector",
          ]
        },
      ]
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "PrunePropagationPolicy=foreground",
          "RespectIgnoreDifferences=true",
        ]
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.argocd_app_repo,
    kubernetes_namespace.langgraph,
  ]
}

resource "kubectl_manifest" "chat_ui_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "chat-ui"
      namespace = kubernetes_namespace.argocd.metadata[0].name
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_app_repo_url
        targetRevision = "HEAD"
        path           = "chat-ui/overlays/dev"

        # Env-specific Ingress + HTTPRoute hosts injected here (same
        # pattern as langgraph-service / rag-service / vllm). The
        # hostname in the source manifest is a placeholder that gets
        # replaced per environment without forking the manifest.
        # Post-Phase 12: legacy Ingress removed; only the HTTPRoute
        # hostname patch remains.
        kustomize = {
          patches = [
            {
              target = {
                kind = "HTTPRoute"
                name = "chat-ui"
              }
              patch = <<-EOT
                - op: replace
                  path: /spec/hostnames/0
                  value: chat.${var.domain}
              EOT
            },
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "chat"
      }
      # Phase #45: canary strategy (was blueGreen in #40). The
      # ignoreDifferences set changed shape:
      #
      # Was (blueGreen):
      #   Service chat-ui          /spec/selector  (activeService)
      #   Service chat-ui-preview  /spec/selector  (previewService)
      #
      # Now (canary):
      #   VirtualService chat-ui-canary-vs route weights (mutated by
      #     argo-rollouts at each setWeight step)
      #   Service chat-ui-stable, /spec/selector
      #   Service chat-ui-canary, /spec/selector
      #
      # The apex `chat-ui` Service is no longer mutated by argo-
      # rollouts in canary mode — its selector stays at bare
      # app=chat-ui and routes to all chat-ui pods. The VS does the
      # actual traffic-weighting.
      ignoreDifferences = [
        {
          group = "networking.istio.io"
          kind  = "VirtualService"
          name  = "chat-ui-canary-vs"
          jsonPointers = [
            "/spec/http/0/route/0/weight",
            "/spec/http/0/route/1/weight",
          ]
        },
        {
          group = ""
          kind  = "Service"
          name  = "chat-ui-stable"
          jsonPointers = [
            "/spec/selector",
          ]
        },
        {
          group = ""
          kind  = "Service"
          name  = "chat-ui-canary"
          jsonPointers = [
            "/spec/selector",
          ]
        },
      ]
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "PrunePropagationPolicy=foreground",
          "RespectIgnoreDifferences=true",
        ]
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.argocd_app_repo,
    kubernetes_namespace.chat,
  ]
}

resource "kubectl_manifest" "qdrant_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "qdrant"
      namespace = kubernetes_namespace.argocd.metadata[0].name
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_app_repo_url
        targetRevision = "HEAD"
        path           = "qdrant/overlays/dev"
        # No env-specific injection — Qdrant has no account/domain-specific values.
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "qdrant"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "PrunePropagationPolicy=foreground",
          # StatefulSets sometimes take several reconcile cycles to settle
          # (PVC provisioning, pod startup). Give ArgoCD a bit more patience.
          "RespectIgnoreDifferences=true",
        ]
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.argocd_app_repo,
  ]
}

resource "kubectl_manifest" "ingestion_service_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "ingestion-service"
      namespace = kubernetes_namespace.argocd.metadata[0].name
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_app_repo_url
        targetRevision = "HEAD"
        path           = "ingestion-service/overlays/dev"
        # No Ingress to patch — ingestion-service is in-cluster only;
        # chat-ui calls it via the K8s Service URL.
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "ingestion"
      }
      # Phase #39: argo-rollouts canary mutates VS weights and the
      # injected Service selectors at runtime. Same pattern as
      # langgraph + rag (Phase #31, #35).
      ignoreDifferences = [
        {
          group = "networking.istio.io"
          kind  = "VirtualService"
          name  = "ingestion-service-canary-vs"
          jsonPointers = [
            "/spec/http/0/route/0/weight",
            "/spec/http/0/route/1/weight",
          ]
        },
        {
          group = ""
          kind  = "Service"
          name  = "ingestion-service-stable"
          jsonPointers = [
            "/spec/selector",
          ]
        },
        {
          group = ""
          kind  = "Service"
          name  = "ingestion-service-canary"
          jsonPointers = [
            "/spec/selector",
          ]
        },
      ]
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "PrunePropagationPolicy=foreground",
          "RespectIgnoreDifferences=true",
        ]
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.argocd_app_repo,
    kubernetes_namespace.ingestion,
  ]
}
