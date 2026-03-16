#!/bin/bash
set -e

echo "=== Creating K3d Cluster ==="
k3d cluster delete dev-cluster 2>/dev/null || true

k3d cluster create dev-cluster \
  --servers 1 \
  --agents 2 \
  --port "80:80@loadbalancer" \
  --port "443:443@loadbalancer" \
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
kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace kubernetes-dashboard --dry-run=client -o yaml | kubectl apply -f -

# Add Helm repos
echo "=== Adding Helm Repos ==="
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install Nginx Ingress first
echo "=== Installing Nginx Ingress ==="
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.service.type=LoadBalancer \
  --wait

echo "=== Waiting for Ingress ==="
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=ingress-nginx \
  -n ingress-nginx \
  --timeout=300s

# Install ArgoCD via Helm
echo "=== Installing ArgoCD via Helm ==="
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values ../charts/argocd/values.yaml \
  --wait

echo "=== Waiting for ArgoCD ==="
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd \
  --timeout=300s

# Apply argocd-cm immediately
echo "=== Applying ArgoCD ConfigMap ==="
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: https://argocd.localhost
  timeout.reconciliation: 10s
  dex.config: |
    connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: Ov23limd3PFv9mcPHlaY
          clientSecret: 3a94802f87d9b53a6e793387d6278dfed7094e56
          loadAllGroups: false
          useLoginAsID: true
          redirectURI: https://argocd.localhost/api/dex/callback
EOF

# Restart dex to pick up config
kubectl rollout restart deployment argocd-dex-server -n argocd
kubectl rollout restart deployment argocd-server -n argocd

# Apply root app - restores everything from GitHub
echo "=== Applying Root App ==="
kubectl apply -f ../root-app/root-app.yaml

# Add hosts entries
echo "=== Adding /etc/hosts entries ==="
if ! grep -q "argocd.localhost" /etc/hosts; then
  echo "127.0.0.1 argocd.localhost jenkins.localhost dashboard.localhost" | sudo tee -a /etc/hosts
  echo "✅ Hosts entries added"
else
  echo "✅ Hosts entries already exist"
fi

# Generate self signed cert
# openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
#   -keyout /tmp/argocd.key \
#   -out /tmp/argocd.crt \
#   -subj "/CN=argocd.localhost" \
#   -addext "subjectAltName=DNS:argocd.localhost"

# # Create secret
# kubectl create secret tls argocd-tls \
#   --cert=/tmp/argocd.crt \
#   --key=/tmp/argocd.key \
#   -n argocd

# Generate self signed cert for argocd
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/argocd.key \
  -out /tmp/argocd.crt \
  -subj "/CN=argocd.localhost" \
  -addext "subjectAltName=DNS:argocd.localhost"

# Create secret in argocd namespace
kubectl create secret tls argocd-server-tls \
  --cert=/tmp/argocd.crt \
  --key=/tmp/argocd.key \
  -n argocd \
  --dry-run=client -o yaml | kubectl apply -f -


# Get ArgoCD password
echo ""
echo "=== ArgoCD Admin Password ==="
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
echo ""

# Get kubectl config for Dashboard access
# Get token
TOKEN=$(kubectl get secret admin-user-token \
  -n kubernetes-dashboard \
  -o jsonpath='{.data.token}' | base64 -d)

# Get cluster CA
CA=$(kubectl get secret admin-user-token \
  -n kubernetes-dashboard \
  -o jsonpath='{.data.ca\.crt}')

# Get cluster server
SERVER=$(kubectl config view --minify \
  -o jsonpath='{.clusters[0].cluster.server}')

# Generate proper kubeconfig
cat > ~/dashboard-kubeconfig.yaml << EOF
apiVersion: v1
kind: Config
clusters:
  - cluster:
      certificate-authority-data: ${CA}
      server: ${SERVER}
    name: k3d-dev-cluster
contexts:
  - context:
      cluster: k3d-dev-cluster
      user: admin-user
    name: admin-user@k3d-dev-cluster
current-context: admin-user@k3d-dev-cluster
users:
  - name: admin-user
    user:
      token: ${TOKEN}
EOF

echo "✅ Kubeconfig saved to ~/dashboard-kubeconfig.yaml"
cat ~/dashboard-kubeconfig.yaml

echo ""
echo "=== Setup Complete ==="
echo "✅ ArgoCD    → https://argocd.localhost"
echo "✅ Jenkins   → http://jenkins.localhost"
echo "✅ Dashboard → http://dashboard.localhost"
echo ""
echo "GitHub OAuth callback URL:"
echo "https://argocd.localhost/api/dex/callback"