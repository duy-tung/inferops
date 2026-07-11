#!/usr/bin/env bash
# IO-T002 evidence: validates the local-overlay Kustomize manifests against a
# REAL k3s API server (not a mock/offline schema check).
#
# RQ-14 compose-pivot (docs/implementation-notes.md "Deviations"): this
# build environment cannot schedule Kubernetes pods (missing
# CAP_SYS_RESOURCE at the runc/nsexec layer — see
# /home/user/tools/k8s-env-probe-report.md). k3s's control plane
# (apiserver/etcd/scheduler/controller-manager) runs as native goroutines
# inside the k3s binary rather than as containers, so it is unaffected and
# comes up normally; `--disable-agent` skips the local kubelet entirely, so
# no Node ever registers and nothing is ever scheduled — this validates
# manifest correctness (schema, defaulting, controller reconciliation:
# Deployment -> ReplicaSet -> Pod, StatefulSet -> Pod, Service ClusterIP
# allocation) against etcd without ever running a container.
#
# Requires: /home/user/tools/k8s-env/{bin,k3s-runtime-bin} on PATH (probe
# report's toolchain — kubectl v1.36.2, k3s v1.30.4+k3s1).
set -uo pipefail

export PATH=/home/user/tools/k8s-env/k3s-runtime-bin:/home/user/tools/k8s-env/bin:"$PATH"
DATA_DIR="${K3S_DATA_DIR:-/home/user/tools/k8s-env/data-inferops}"
KUBECONFIG_PATH="${K3S_KUBECONFIG:-/home/user/tools/k8s-env/kubeconfig-inferops}"
LOG_FILE="${K3S_LOG:-/home/user/tools/k8s-env/k3s-server-io-t002.log}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "== starting k3s (server-only, --disable-agent: no kubelet, no pod scheduling) =="
mkdir -p "$DATA_DIR"
if ! pgrep -f "k3s server.*$DATA_DIR" >/dev/null; then
  nohup k3s server \
    --disable-agent \
    --data-dir="$DATA_DIR" \
    --write-kubeconfig="$KUBECONFIG_PATH" \
    --write-kubeconfig-mode=644 \
    --disable=traefik,servicelb,metrics-server,local-storage,coredns \
    > "$LOG_FILE" 2>&1 &
  disown
  echo "k3s server starting (pid $!), waiting for API to come up..."
  for _ in $(seq 1 30); do
    KUBECONFIG="$KUBECONFIG_PATH" kubectl get --raw /healthz >/dev/null 2>&1 && break
    sleep 2
  done
else
  echo "k3s server already running against $DATA_DIR"
fi

# /healthz goes "ok" before the aggregated API-group/openapi discovery cache
# has warmed up (observed: `kubectl apply`/`kubectl get` briefly return
# "the server could not find the requested resource" right after /healthz
# first succeeds). Wait for a real API-group-backed call to succeed too.
for _ in $(seq 1 30); do
  KUBECONFIG="$KUBECONFIG_PATH" kubectl get namespace default >/dev/null 2>&1 && break
  sleep 2
done
sleep 5  # let the last few post-start hooks (rbac/scheduling bootstrap) finish so /healthz is clean below

export KUBECONFIG="$KUBECONFIG_PATH"

echo
echo "== kubectl get --raw /healthz =="
kubectl get --raw /healthz

echo
echo "== kubectl version (client + server) =="
kubectl version

echo
echo "== kustomize build clusters/local (schema/render check) =="
kubectl kustomize "$REPO_ROOT/clusters/local" >/tmp/inferops-rendered-local.yaml
echo "rendered $(grep -c '^kind:' /tmp/inferops-rendered-local.yaml) objects, 0 build errors"

echo
echo "== kubectl apply -k clusters/local (real apply to etcd) =="
kubectl apply -k "$REPO_ROOT/clusters/local"

echo
echo "== kubectl apply --dry-run=server -k clusters/local (re-run: server-side admission + schema re-validation) =="
kubectl apply --dry-run=server -k "$REPO_ROOT/clusters/local"

sleep 5  # let the Deployment/StatefulSet controllers create their Pod objects before we list them

echo
echo "== kubectl get all -n inferops-local -o wide (expect all pods Pending — zero Nodes registered) =="
kubectl get all -n inferops-local -o wide

echo
echo "== kubectl get nodes (expect none — --disable-agent, proving no scheduling occurred) =="
kubectl get nodes

echo
echo "== kubectl get events -n inferops-local --sort-by=.lastTimestamp =="
kubectl get events -n inferops-local --sort-by=.lastTimestamp
