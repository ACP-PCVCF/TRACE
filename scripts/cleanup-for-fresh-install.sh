#!/bin/bash

echo "=== CLEANUP SCRIPT FOR FRESH INSTALLATION SIMULATION ==="
echo "This will remove all cached repositories and resources"
echo ""

# 1. Remove all Helm repositories
echo "1. Removing Helm repositories..."
helm repo remove camunda 2>/dev/null || echo "  - camunda repo not found"
echo "  - bitnami repo not needed (using local .tgz)"

# 2. Clear Helm cache
echo "2. Clearing Helm cache..."
rm -rf ~/.cache/helm 2>/dev/null || true
rm -rf ~/.config/helm/repositories.yaml 2>/dev/null || true
rm -rf ~/.local/share/helm 2>/dev/null || true

# 3. Remove Docker images (Kafka related)
echo "3. Removing Docker images..."
docker rmi apache/kafka:latest 2>/dev/null || echo "  - apache/kafka:latest not found"
docker rmi bitnamilegacy/kafka:4.0.0-debian-12-r10 2>/dev/null || echo "  - bitnamilegacy image not found"
docker rmi bitnami/kafka:latest 2>/dev/null || echo "  - bitnami/kafka:latest not found"

# 4. Clean up Kind cluster
echo "4. Cleaning up Kind cluster..."
kind delete cluster --name trace 2>/dev/null || echo "  - trace cluster not found"

# 5. Remove Kubernetes config cache
echo "5. Clearing Kubernetes cache..."
rm -rf ~/.kube/cache 2>/dev/null || true

# 6. Clear any Helm chart downloads
echo "6. Clearing Helm chart cache..."
rm -rf ~/.cache/helm/repository 2>/dev/null || true

echo ""
echo "✅ All caches cleared! Ready for fresh installation."
echo ""
echo "To test fresh installation, run:"
echo "  bash scripts/kind/setup-helm.sh"
