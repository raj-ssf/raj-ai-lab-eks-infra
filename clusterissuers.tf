resource "kubernetes_manifest" "letsencrypt_staging" {
    manifest = {
      apiVersion = "cert-manager.io/v1"
      kind       = "ClusterIssuer"
      metadata = {
        name = "letsencrypt-staging"
      }
      spec = {
        acme = {
          server = "https://acme-staging-v02.api.letsencrypt.org/directory"
          email  = var.acme_email
          privateKeySecretRef = {
            name = "letsencrypt-staging-account-key"
          }
          solvers = [{
            dns01 = {
              route53 = {
                region       = var.region
                hostedZoneID = data.aws_route53_zone.main.zone_id
              }
            }
            selector = {
              dnsZones = [var.domain]
            }
          }]
        }
      }
    }
    depends_on = [helm_release.cert_manager]
  }

  resource "kubernetes_manifest" "letsencrypt_prod" {
    manifest = {
      apiVersion = "cert-manager.io/v1"
      kind       = "ClusterIssuer"
      metadata = {
        name = "letsencrypt-prod"
      }
      spec = {
        acme = {
          server = "https://acme-v02.api.letsencrypt.org/directory"
          email  = var.acme_email
          privateKeySecretRef = {
            name = "letsencrypt-prod-account-key"
          }
          solvers = [{
            dns01 = {
              route53 = {
                region       = var.region
                hostedZoneID = data.aws_route53_zone.main.zone_id
              }
            }
            selector = {
              dnsZones = [var.domain]
            }
          }]
        }
      }
    }
    depends_on = [helm_release.cert_manager]
  }