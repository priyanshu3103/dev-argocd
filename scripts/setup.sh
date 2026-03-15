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

echo "=== Patching ArgoCD Service ==="
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 80, "nodePort": 30090, "targetPort": 8080, "name": "http"}, {"port": 443, "nodePort": 30443, "targetPort": 8080, "name": "https"}]}}'

echo "=== Applying Root App ==="
kubectl apply -f root-app/root-app.yaml

echo "=== ArgoCD Password ==="
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d

echo ""
echo "=== Setup Complete ==="
echo "ArgoCD: https://localhost:30443"
echo "Jenkins: http://localhost:30080"