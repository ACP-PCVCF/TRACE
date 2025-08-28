#!/bin/bash
set -e

NAMESPACE1="proving-system"
NAMESPACE2="verifier-system"
KIND_CLUSTER_NAME="trace"

echo "TRACE Helm Deployment Script"

# Check if kind cluster exists
echo "Checking if kind cluster '$KIND_CLUSTER_NAME' exists..."
if ! kind get clusters | grep -q "^$KIND_CLUSTER_NAME$"; then
  echo "Creating kind cluster '$KIND_CLUSTER_NAME'..."
  kind create cluster --name $KIND_CLUSTER_NAME
else
  echo "Kind cluster '$KIND_CLUSTER_NAME' already exists."
fi

# Add Helm repositories
echo "Checking and adding Helm repositories..."
if ! helm repo list | grep -q camunda; then
  echo "Adding Camunda Helm repo..."
  helm repo add camunda https://helm.camunda.io
else
  echo "Camunda Helm repo already added."
fi

echo "Updating Helm repos..."
helm repo update

# Create Namespaces
for ns in "$NAMESPACE1" "$NAMESPACE2"; do
  echo "Checking if namespace '$ns' exists..."
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "Creating namespace '$ns'"
    kubectl create namespace "$ns"
  else
    echo "Namespace '$ns' already exists."
  fi
done

# Install Camunda Platform
echo "Installing Camunda Platform..."
if ! helm list -n $NAMESPACE1 | grep -q camunda; then
  echo "Installing Camunda in namespace $NAMESPACE1..."
  helm install camunda camunda/camunda-platform \
    -n $NAMESPACE1 --create-namespace \
    -f ./camunda-platform/camunda-platform-core-kind-values.yaml
else
  echo "Camunda is already installed in $NAMESPACE1."
fi

echo "Waiting for Camunda pods to be created..."
sleep 30

echo "Waiting for Camunda pods to be ready..."
kubectl wait --for=condition=ready pod --all -n $NAMESPACE1 --timeout=600s || {
  echo "Warning: Some Camunda pods may not be ready yet, continuing..."
}

# Install Kafka
echo "Installing Kafka..."
if ! helm list -n $NAMESPACE1 | grep -q kafka; then
  echo "Installing Kafka in namespace $NAMESPACE1..."
  echo "Using local Kafka chart (.tgz) with legacy images for brownout compatibility..."
  helm install kafka ./kafka-service/kafka-32.3.10.tgz \
    --namespace $NAMESPACE1 \
    --create-namespace \
    -f kafka-service/kafka-values.yaml
else
  echo "Kafka is already installed in $NAMESPACE1."
fi

echo "Waiting for Kafka pods to be ready..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=kafka -n $NAMESPACE1 --timeout=600s || {
  echo "Warning: Kafka pods may not be ready yet, continuing..."
}

echo "Creating Kafka topics..."
kubectl apply -f kafka-service/kafka-topic-job.yaml

echo "Waiting for Kafka topics job to complete..."
kubectl wait --for=condition=complete job/create-kafka-topics -n $NAMESPACE1 --timeout=300s || {
  echo "Warning: Kafka topics job may not have completed, continuing..."
}

echo "Configuring Kafka broker message size limits..."
kubectl run kafka-config-all --rm -it --restart=Never --image=bitnamilegacy/kafka:4.0.0-debian-12-r10 --namespace=proving-system -- bash -c "for broker in 0 1 2; do kafka-configs.sh --bootstrap-server kafka.proving-system.svc.cluster.local:9092 --entity-type brokers --entity-name \$broker --alter --add-config message.max.bytes=52428800; done" || {
  echo "Warning: Kafka configuration may have failed, continuing..."
}

# Pull Docker images
echo "Pulling Docker images from registry..."
docker pull ghcr.io/acp-pcvcf/sensor-data-service:latest
docker pull ghcr.io/acp-pcvcf/camunda-service:latest
docker pull ghcr.io/acp-pcvcf/proving-service:latest
docker pull ghcr.io/acp-pcvcf/verifier:latest
docker pull ghcr.io/acp-pcvcf/pcf-registry:latest
docker pull ghcr.io/acp-pcvcf/sensor-key-registry:latest

# Load images into kind cluster
echo "Loading Docker images into kind cluster..."
kind load docker-image ghcr.io/acp-pcvcf/sensor-data-service:latest --name $KIND_CLUSTER_NAME
kind load docker-image ghcr.io/acp-pcvcf/camunda-service:latest --name $KIND_CLUSTER_NAME
kind load docker-image ghcr.io/acp-pcvcf/proving-service:latest --name $KIND_CLUSTER_NAME
kind load docker-image ghcr.io/acp-pcvcf/verifier:latest --name $KIND_CLUSTER_NAME
kind load docker-image ghcr.io/acp-pcvcf/pcf-registry:latest --name $KIND_CLUSTER_NAME
kind load docker-image ghcr.io/acp-pcvcf/sensor-key-registry:latest --name $KIND_CLUSTER_NAME

# Install microservices using Helm
echo "=== Installing Microservices using Helm ==="

echo "Installing PCF Registry..."
helm upgrade --install pcf-registry ./pcf-registry/pcf-deployment-charts -n $NAMESPACE1

echo "Installing Sensor Data Service..."
helm upgrade --install sensor-data-service ./sensor-data-service/helm-chart -n $NAMESPACE1

echo "Installing Camunda Service..."
helm upgrade --install camunda-service ./camunda-service/helm-chart -n $NAMESPACE1

echo "Installing Proving Service..."
helm upgrade --install proving-service ./proving-service/helm-chart -n $NAMESPACE1

echo "Installing Sensor Key Registry..."
helm upgrade --install sensor-key-registry ./sensor-key-registry/helm-chart -n $NAMESPACE2

echo "Installing Verifier Service..."
helm upgrade --install verifier-service ./verifier-service/helm-chart -n $NAMESPACE2

echo "=== Deployment Status ==="
echo "Waiting for all deployments to be ready..."

# Wait for deployments in proving-system namespace
echo "Checking deployments in $NAMESPACE1..."
kubectl wait --for=condition=available deployment --all -n $NAMESPACE1 --timeout=600s || {
  echo "Warning: Some deployments in $NAMESPACE1 may not be ready"
}

# Wait for deployments in verifier-system namespace
echo "Checking deployments in $NAMESPACE2..."
kubectl wait --for=condition=available deployment --all -n $NAMESPACE2 --timeout=600s || {
  echo "Warning: Some deployments in $NAMESPACE2 may not be ready"
}

echo "Final Status"
echo "Pods in $NAMESPACE1:"
kubectl get pods -n $NAMESPACE1

echo "Pods in $NAMESPACE2:"
kubectl get pods -n $NAMESPACE2

echo "Services in $NAMESPACE1:"
kubectl get services -n $NAMESPACE1

echo "Services in $NAMESPACE2:"
kubectl get services -n $NAMESPACE2

echo "Deployment Complete"
echo "All services have been deployed using Helm charts!"
echo "You can check the status with:"
echo "  kubectl get all -n $NAMESPACE1"
echo "  kubectl get all -n $NAMESPACE2"
