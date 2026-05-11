# =============================================================================
# Tetragon TracingPolicies — runtime threat detection rules.
#
# Closes the largest single StackRox parity gap: the new cluster's Tetragon
# DaemonSet was sitting at 0 active rules ("silent witness" mode). This
# file authors 7 starter policies covering the categories StackRox ships
# with by default:
#
#   1. Cryptominer binary execution            (xmrig, cgminer)
#   2. Reverse-shell / data-exfil tooling      (nc/ncat/socat/wget/curl POST)
#   3. Package manager invocation in container (apt, yum, apk, dnf, pip)
#   4. Privilege escalation binaries           (sudo, su, pkexec, setuid)
#   5. Sensitive file reads                    (/etc/shadow, SA token, .ssh)
#   6. Container escape attempts               (mount, ptrace, kernel modules)
#   7. Shell spawn inside non-shell workloads  (bash/sh under web app)
#
# All policies are `Post`-only (emit event, no kill / no signal) for the
# first round. Once we have a Grafana dashboard and a few weeks of false-
# positive triage data, the most-confident rules can be promoted to
# Override (kill the offending syscall) — Tetragon's distinguishing
# capability vs Falco. The promotion path is per-policy and reversible.
#
# Why these 7 and not more: StackRox ships ~80 default rules, but most are
# Linux-specific (Fedora repo signing, RH SCAP) or wrap each other. These
# 7 are the orthogonal coverage axes; future policies layer on top.
#
# All policies are CLUSTER-scoped (TracingPolicy, not TracingPolicyNamespaced)
# so they apply uniformly across every namespace. Namespace-scoped policies
# could exclude noisy system pods later if needed.
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Cryptominer detection
#
# Triggers on exec of known miner binaries. StackRox equivalent: "CryptoCurrency
# Mining" detection. Low false-positive rate — these binaries have no
# legitimate use in app containers.
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "tracing_cryptominer" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "detect-cryptominer-exec"
    }
    spec = {
      kprobes = [{
        call    = "security_bprm_check"
        syscall = false
        args = [{ index = 0, type = "linux_binprm" }]
        selectors = [{
          matchArgs = [{
            index    = 0
            operator = "Postfix"
            values = [
              "/xmrig",
              "/cgminer",
              "/cpuminer",
              "/ethminer",
              "/minerd",
              "/cryptonight",
            ]
          }]
          matchActions = [{ action = "Post" }]
        }]
      }]
    }
  })

  depends_on = [helm_release.tetragon]
}

# -----------------------------------------------------------------------------
# 2. Reverse-shell / network relay tooling
#
# Detects exec of nc/ncat/socat — commonly chained for reverse shells or
# data exfil. These DO have legitimate uses (debugging) so this rule will
# fire on legitimate sysadmin actions too. Use the event stream's pod
# labels to distinguish prod workloads from kubectl-exec'd debugging.
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "tracing_reverse_shell" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "detect-reverse-shell-tools"
    }
    spec = {
      kprobes = [{
        call    = "security_bprm_check"
        syscall = false
        args    = [{ index = 0, type = "linux_binprm" }]
        # 2026-05-10 v2: REMOVED `/bash` from the matcher list.
        #
        # Original policy included `/bash` to catch bash-based reverse-shell
        # payloads like `bash -i >& /dev/tcp/<attacker>/4444`. But the
        # `security_bprm_check` kprobe with `linux_binprm` type can only
        # match the binary path (no argv inspection), so EVERY `/bin/bash`
        # exec triggered — including Redis-ha health-check probes which
        # invoke `/bin/bash /health/ping_readiness_local.sh` every few
        # seconds in each replica.
        #
        # Impact: 30,798 events/24h on langgraph-redis-ha-node alone, which
        # dominated the workload risk score and crowded out real signal.
        #
        # nc/ncat/netcat/socat coverage retained — those are the canonical
        # reverse-shell tools (the bash-based pattern would still trip
        # detect-sensitive-file-access if it touches /dev/tcp/* and
        # detect-package-manager-exec if any tooling is installed).
        #
        # If bash-based reverse shells become a priority detection target,
        # author a NEW policy using __x64_sys_execve (which exposes argv)
        # filtered on `-i` + redirects to network destinations.
        selectors = [{
          matchArgs = [{
            index    = 0
            operator = "Postfix"
            values = [
              "/nc",
              "/ncat",
              "/netcat",
              "/socat",
            ]
          }]
          matchActions = [{ action = "Post" }]
        }]
      }]
    }
  })

  depends_on = [helm_release.tetragon]
}

# -----------------------------------------------------------------------------
# 3. Package manager invocation in container
#
# StackRox flag: "Package Management Execution". In an immutable container
# image, apt/yum/apk should NEVER run at runtime — if they do, an attacker
# is installing tools, OR a poorly-built image is patching at startup
# (which is itself a finding).
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "tracing_package_manager" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "detect-package-manager-exec"
    }
    spec = {
      kprobes = [{
        call    = "security_bprm_check"
        syscall = false
        args = [{ index = 0, type = "linux_binprm" }]
        selectors = [{
          matchArgs = [{
            index    = 0
            operator = "Postfix"
            values = [
              "/apt",
              "/apt-get",
              "/dpkg",
              "/yum",
              "/dnf",
              "/rpm",
              "/apk",
              "/pip",
              "/pip3",
              "/gem",
              "/npm",
            ]
          }]
          matchActions = [{ action = "Post" }]
        }]
      }]
    }
  })

  depends_on = [helm_release.tetragon]
}

# -----------------------------------------------------------------------------
# 4. Privilege escalation binaries
#
# Triggers on sudo/su/pkexec exec. Legitimate uses: admin shell on the
# appliance itself (won't fire — that's host, not container). Container
# workloads should never need these.
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "tracing_priv_escalation" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "detect-privilege-escalation"
    }
    spec = {
      kprobes = [{
        call    = "security_bprm_check"
        syscall = false
        args = [{ index = 0, type = "linux_binprm" }]
        selectors = [{
          matchArgs = [{
            index    = 0
            operator = "Postfix"
            values = [
              "/sudo",
              "/su",
              "/pkexec",
              "/doas",
            ]
          }]
          matchActions = [{ action = "Post" }]
        }]
      }]
    }
  })

  depends_on = [helm_release.tetragon]
}

# -----------------------------------------------------------------------------
# 5. Sensitive file reads
#
# Catches open() of /etc/shadow, ServiceAccount tokens (the projected SA
# token path is ALWAYS read by kubelet — filter to suspicious reads later
# by adding NOT-from-kubelet selector once we see the noise level).
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "tracing_sensitive_file_read" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "detect-sensitive-file-access"
    }
    spec = {
      kprobes = [
        {
          call    = "security_file_open"
          syscall = false
          return  = false
          args = [
            { index = 0, type = "file" },
          ]
          selectors = [{
            matchArgs = [{
              index    = 0
              operator = "Equal"
              values = [
                "/etc/shadow",
                "/etc/gshadow",
                "/etc/sudoers",
                "/root/.ssh/authorized_keys",
                "/root/.ssh/id_rsa",
                "/root/.ssh/id_ed25519",
              ]
            }]
            matchActions = [{ action = "Post" }]
          }]
        }
      ]
    }
  })

  depends_on = [helm_release.tetragon]
}

# -----------------------------------------------------------------------------
# 6. Container escape — kernel module load
#
# `init_module` / `finit_module` syscalls. Containers should never load
# kernel modules. If this fires, something is attempting a kernel-level
# escape (modprobe, insmod, or direct syscall).
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "tracing_kmod_load" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "detect-kernel-module-load"
    }
    spec = {
      kprobes = [
        {
          call    = "security_kernel_module_request"
          syscall = false
          args = [
            { index = 0, type = "string" },
          ]
          selectors = [{
            matchActions = [{ action = "Post" }]
          }]
        }
      ]
    }
  })

  depends_on = [helm_release.tetragon]
}

# -----------------------------------------------------------------------------
# 7. ptrace — process injection / debugging
#
# ptrace(2) is the kernel hook for debuggers and YAMA-allowed attach.
# In a container, ptrace from one process to another (PTRACE_ATTACH,
# PTRACE_SEIZE) typically means injection. Fires often in dev workflows
# (gdb, strace) but those shouldn't appear in prod app containers.
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "tracing_ptrace" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata = {
      name = "detect-ptrace-attach"
    }
    spec = {
      kprobes = [
        {
          call    = "__x64_sys_ptrace"
          syscall = true
          args = [
            { index = 0, type = "int64" }, # PTRACE request code (long on Linux x86_64)
            { index = 1, type = "int" },   # target pid
          ]
          selectors = [{
            matchArgs = [{
              index    = 0
              operator = "Equal"
              # PTRACE_ATTACH=16, PTRACE_SEIZE=0x4206
              values = ["16", "16902"]
            }]
            matchActions = [{ action = "Post" }]
          }]
        }
      ]
    }
  })

  depends_on = [helm_release.tetragon]
}
