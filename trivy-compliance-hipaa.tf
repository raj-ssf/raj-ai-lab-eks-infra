# =============================================================================
# Trivy HIPAA Technical Safeguards compliance profile.
#
# Closes StackRox parity gap #5: out of the box Trivy ships CIS-K8s-1.23,
# NSA-1.0, PSS-baseline, and PSS-restricted profiles — none address HIPAA's
# §164.312 Technical Safeguards directly. This file authors a custom
# ClusterComplianceReport that maps each of the 5 HIPAA technical
# safeguards to the relevant Trivy/Aquasecurity AVD checks Trivy already
# runs on every workload.
#
# IMPORTANT CAVEAT: this is a STARTING-POINT mapping suitable for
# engineering-team self-assessment. It is NOT a compliance-officer-approved
# HIPAA audit profile. Before using the resulting report in any actual
# audit submission, have it reviewed by Myriad's compliance / legal team.
# The mapping is one engineer's reading of which K8s controls reasonably
# evidence each HIPAA technical safeguard — the auditor may disagree,
# require additional controls, or want different evidence formats.
#
# References:
#   - 45 CFR §164.312 (Technical Safeguards):
#     https://www.law.cornell.edu/cfr/text/45/164.312
#   - Trivy AVD check catalog: https://avd.aquasec.com/misconfig/kubernetes/
# =============================================================================

resource "kubectl_manifest" "trivy_compliance_hipaa" {
  yaml_body = yamlencode({
    apiVersion = "aquasecurity.github.io/v1alpha1"
    kind       = "ClusterComplianceReport"
    metadata = {
      name = "hipaa-technical-safeguards-0.1"
      labels = {
        "app.kubernetes.io/name" = "trivy-operator"
        "purpose"                = "stackrox-parity-hipaa-mapping"
      }
    }
    spec = {
      cron       = "0 */6 * * *" # every 6h; HIPAA controls don't change minute-to-minute
      reportType = "summary"
      compliance = {
        id          = "hipaa-tech-safeguards-0.1"
        title       = "HIPAA §164.312 Technical Safeguards (starter mapping)"
        description = "Per-control evidence mapped from K8s/container security checks. NOT auditor-approved; engineering self-assessment only."
        version     = "0.1"
        platform    = "k8s"  # required by CRD; same value the built-in profiles use
        type        = "hipaa" # required by CRD; identifies this as a HIPAA compliance spec
        relatedResources = [
          "https://www.law.cornell.edu/cfr/text/45/164.312",
        ]
        controls = [
          # ---- §164.312(a)(1) Access Control ----
          {
            id          = "164.312-a-1-unique-user-id"
            name        = "Unique user identification — workloads don't use shared default accounts"
            description = "(a)(1)(i) — Assign a unique name and/or number for identifying and tracking user identity. Kubernetes evidence: workloads must not mount the default ServiceAccount token; each workload has its own SA."
            severity    = "HIGH"
            checks = [
              { id = "AVD-KSV-0036" }, # disable serviceAccount token mounting unless required
            ]
          },
          {
            id          = "164.312-a-1-no-anonymous-access"
            name        = "No anonymous access to ePHI"
            description = "(a)(1) — Implement technical policies and procedures that allow access only to those granted access rights. Kubernetes evidence: anonymous-auth disabled, no wildcard RBAC."
            severity    = "HIGH"
            checks = [
              { id = "AVD-KCV-0001" }, # API server --anonymous-auth=false
              { id = "AVD-KSV-0044" }, # No wildcards in cluster roles
              { id = "AVD-KSV-0045" }, # No wildcards in roles
            ]
          },
          {
            id          = "164.312-a-2-iv-encryption-decryption"
            name        = "Encryption and decryption of ePHI at rest"
            description = "(a)(2)(iv) — Implement a mechanism to encrypt and decrypt ePHI. Kubernetes evidence: secrets encryption at rest, etcd encryption enabled."
            severity    = "CRITICAL"
            checks = [
              { id = "AVD-KCV-0029" }, # API server --encryption-provider-config set
              { id = "AVD-KCV-0042" }, # etcd --auto-tls=false (do not use self-signed)
            ]
          },

          # ---- §164.312(b) Audit Controls ----
          {
            id          = "164.312-b-audit-logging"
            name        = "Audit logging of access to ePHI"
            description = "(b) — Implement hardware, software, and/or procedural mechanisms that record and examine activity in information systems. Kubernetes evidence: API server audit logging enabled."
            severity    = "HIGH"
            checks = [
              { id = "AVD-KCV-0019" }, # --audit-log-path is set
              { id = "AVD-KCV-0020" }, # --audit-log-maxage >= 30
              { id = "AVD-KCV-0021" }, # --audit-log-maxbackup >= 10
              { id = "AVD-KCV-0022" }, # --audit-log-maxsize >= 100
            ]
          },

          # ---- §164.312(c)(1) Integrity ----
          {
            id          = "164.312-c-1-image-integrity"
            name        = "Container image integrity — no mutable tags"
            description = "(c)(1) — Implement policies and procedures to protect ePHI from improper alteration or destruction. Kubernetes evidence: images use immutable tags (no :latest), images are signed."
            severity    = "HIGH"
            checks = [
              { id = "AVD-KSV-0013" }, # No 'latest' image tag
            ]
          },
          {
            id          = "164.312-c-1-read-only-fs"
            name        = "Read-only root filesystem for ePHI-handling workloads"
            description = "(c)(1) — Container filesystem must be read-only to prevent in-pod alteration of binaries. Defense-in-depth against post-compromise mutation."
            severity    = "MEDIUM"
            checks = [
              { id = "AVD-KSV-0014" }, # Root filesystem is read-only
            ]
          },

          # ---- §164.312(d) Person/Entity Authentication ----
          {
            id          = "164.312-d-no-privileged-containers"
            name        = "No privileged containers (defense for entity auth bypass)"
            description = "(d) — Verify that the entity seeking access is the one claimed. Kubernetes evidence: containers cannot run privileged (would bypass all entity-auth on the host)."
            severity    = "CRITICAL"
            checks = [
              { id = "AVD-KSV-0017" }, # Container is privileged
              { id = "AVD-KSV-0001" }, # No privilege escalation
            ]
          },
          {
            id          = "164.312-d-no-host-namespace-sharing"
            name        = "No host PID/IPC/Network sharing"
            description = "(d) — Containers sharing host namespaces can spoof identity of host processes."
            severity    = "HIGH"
            checks = [
              { id = "AVD-KSV-0008" }, # Access to host PID
              { id = "AVD-KSV-0009" }, # Access to host IPC
              { id = "AVD-KSV-0010" }, # Access to host network
            ]
          },

          # ---- §164.312(e)(1) Transmission Security ----
          {
            id          = "164.312-e-1-tls-everywhere"
            name        = "TLS required for all API server communication"
            description = "(e)(1) — Implement technical security measures to guard against unauthorized access to ePHI transmitted over a network. Kubernetes evidence: API server TLS enabled, weak ciphers disabled."
            severity    = "HIGH"
            checks = [
              { id = "AVD-KCV-0011" }, # --tls-cert-file is set
              { id = "AVD-KCV-0012" }, # --tls-private-key-file is set
              { id = "AVD-KCV-0027" }, # --tls-cipher-suites restricts to strong ciphers
            ]
          },
          {
            id          = "164.312-e-1-no-insecure-capabilities"
            name        = "Containers don't add NET_RAW (no raw packet capture)"
            description = "(e)(1) — NET_RAW capability allows containers to sniff/spoof network traffic, breaking the assumed transmission security."
            severity    = "MEDIUM"
            checks = [
              { id = "AVD-KSV-0007" },  # Container can't add NET_RAW
              { id = "AVD-KSV-0022" },  # No capabilities added beyond default
            ]
          },
        ]
      }
    }
  })

  depends_on = [helm_release.trivy_operator]
}

output "hipaa_compliance_report_hint" {
  value       = "kubectl get clustercompliancereport hipaa-technical-safeguards-0.1 -o yaml | yq '.status.summary'"
  description = "Tail HIPAA compliance report status (per-control pass/fail counts)"
}
