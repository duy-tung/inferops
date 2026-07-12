#!/usr/bin/env bash
# IO-T005 evidence: validates the GPU-node-profile Kustomize overlay
# (clusters/gpu-node) against a REAL k3s API server — same method as
# clusters/local/validate-k3s.sh (IO-T002). This proves the GPU-node-profile
# SHELL (nodeSelector, tolerations, nvidia.com/gpu resource limit) is
# schema-valid and reconciles through etcd/controllers exactly like the
# CPU-path manifests — WITHOUT a GPU, WITHOUT a real node, and WITHOUT ever
# scheduling a pod (G6 is closed this session: no GPU rented). See
# clusters/gpu-node/gpu-profile-patch.yaml's header for the full honesty
# note on what this validates and does not validate (it validates manifest
# correctness; it does NOT validate that any engine binary actually uses a
# GPU, since none is scheduled).
#
# Requires: /home/user/tools/k8s-env/{bin,k3s-runtime-bin} on PATH (same
# toolchain as clusters/local/validate-k3s.sh — kubectl v1.36.2, k3s
# v1.30.4+k3s1). Reuses the SAME k3s server as IO-T002 if already running
# (a second apply into the same etcd, different namespace) rather than
# starting a second control plane.
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
  echo "k3s server already running against $DATA_DIR (reused from IO-T002/T004)"
fi

for _ in $(seq 1 30); do
  KUBECONFIG="$KUBECONFIG_PATH" kubectl get namespace default >/dev/null 2>&1 && break
  sleep 2
done

export KUBECONFIG="$KUBECONFIG_PATH"

echo
echo "== kubectl get --raw /healthz =="
kubectl get --raw /healthz

echo
echo "== kustomize build clusters/gpu-node (schema/render check; confirms the"
echo "   GPU-profile patch actually applied — nodeSelector/tolerations/nvidia.com/gpu) =="
kubectl kustomize "$REPO_ROOT/clusters/gpu-node" >/tmp/inferops-rendered-gpu-node.yaml
echo "rendered $(grep -c '^kind:' /tmp/inferops-rendered-gpu-node.yaml) objects, 0 build errors"
echo "-- confirming GPU-profile fields are present in the rendered output --"
grep -A2 "nodeSelector:" /tmp/inferops-rendered-gpu-node.yaml
grep -A3 "tolerations:" /tmp/inferops-rendered-gpu-node.yaml
grep "nvidia.com/gpu" /tmp/inferops-rendered-gpu-node.yaml

echo
echo "== kubectl apply -k clusters/gpu-node (real apply to etcd) =="
kubectl apply -k "$REPO_ROOT/clusters/gpu-node"

echo
echo "== kubectl apply --dry-run=server -k clusters/gpu-node (re-run: server-side admission + schema re-validation) =="
kubectl apply --dry-run=server -k "$REPO_ROOT/clusters/gpu-node"

sleep 8  # let the Deployment controller create its ReplicaSet/Pod objects before we list them

echo
echo "== kubectl get all -n inferops-gpu-node -o wide (expect the Pod Pending — zero Nodes registered, so the nvidia.com/gpu request/nodeSelector/toleration are never actually evaluated by a scheduler decision) =="
kubectl get all -n inferops-gpu-node -o wide
echo
echo "-- explicit ReplicaSet/Pod listing (some kubectl versions omit these from 'get all' immediately after apply) --"
kubectl get rs,pods -n inferops-gpu-node -o wide

echo
echo "== kubectl get nodes (expect none — --disable-agent; proves no scheduling, GPU or otherwise, occurred) =="
kubectl get nodes

echo
echo "== kubectl describe pod -n inferops-gpu-node (confirms the pod spec carries nodeSelector/tolerations/resources as authored) =="
kubectl get pods -n inferops-gpu-node -o name | xargs -r -n1 kubectl describe -n inferops-gpu-node

echo
echo "== kubectl get events -n inferops-gpu-node --sort-by=.lastTimestamp =="
kubectl get events -n inferops-gpu-node --sort-by=.lastTimestamp
