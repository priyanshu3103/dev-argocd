#!/bin/bash
set -e

echo "=== Creating K3d Cluster ==="
k3d cluster delete dev-cluster 2>/dev/null || true

k3d cluster create dev-cluster \
  --servers 1 \
  --agents 2 \
  --port "30080:30080@loadbalancer" \
  --port "30443:30443@loadbalancer" \
  --port "30090:30090@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0" \
  --wait

# Set context
k3d kubeconfig merge dev-cluster --kubeconfig-merge-default
kubectl config use-context k3d-dev-cluster

echo "=== Nodes ==="
kubectl get nodes

# Create namespaces
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -

# Add ArgoCD helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "=== Installing ArgoCD via Helm ==="
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values charts/argocd/values.yaml \
  --wait

echo "=== Waiting for ArgoCD ==="
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd \
  --timeout=300s

echo "=== Patching All Services ==="

# ArgoCD
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 80, "nodePort": 30090, "targetPort": 8080, "name": "http"}, {"port": 443, "nodeOnly": 30443, "targetPort": 8080, "name": "https"}]}}'
echo "✅ ArgoCD    → https://localhost:30443"

# Wait for Jenkins then patch
until kubectl get svc jenkins -n jenkins &>/dev/null; do
  echo "Waiting for Jenkins service..."
  sleep 10
done
kubectl patch svc jenkins -n jenkins \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 8080, "nodePort": 30080, "targetPort": 8080, "name": "http"}]}}'
echo "✅ Jenkins   → http://localhost:30080"

# Wait for Dashboard then patch
until kubectl get svc kubernetes-dashboard -n kubernetes-dashboard &>/dev/null; do
  echo "Waiting for Dashboard service..."
  sleep 10
done
kubectl patch svc kubernetes-dashboard -n kubernetes-dashboard \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 443, "nodePort": 30444, "targetPort": 8443, "name": "https"}]}}'
echo "✅ Dashboard → https://localhost:30444"

echo ""
echo "=== All Services Ready ==="
echo "ArgoCD    → https://localhost:30443"
echo "Jenkins   → http://localhost:30080"
echo "Dashboard → https://localhost:30444"