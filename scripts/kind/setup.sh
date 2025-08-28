#!/bin/bash
set -e

NAMESPACE1="proving-system"
NAMESPACE2="verifier-system"
KIND_CLUSTER_NAME="trace"

echo "Checking if kind cluster '$KIND_CLUSTER_NAME' exists..."
if ! kind get clusters | grep -q "^$KIND_CLUSTER_NAME$"; then
  echo "Creating kind cluster '$KIND_CLUSTER_NAME'..."
  kind create cluster --name $KIND_CLUSTER_NAME
else
  echo "Kind cluster '$KIND_CLUSTER_NAME' already exists."
fi

echo "Checking if Camunda Helm repo is added..."
if ! helm repo list | grep -q camunda; then
  echo "Adding Camunda Helm repo..."
  helm repo add camunda https://helm.camunda.io
else
  echo "Camunda Helm repo already added."
fi

echo "Updating Helm repos..."
helm repo update

# Ensure Namespaces exist
for ns in "$NAMESPACE1" "$NAMESPACE2"; do
  echo "Checking if namespace '$ns' exists..."
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "Adding namespace '$ns'"
    kubectl create namespace "$ns"
  else
    echo "Namespace '$ns' already exists."
  fi
done

# Install Camunda
if ! helm list -n $NAMESPACE1 | grep -q camunda; then
  echo "Installing Camunda in namespace $NAMESPACE1..."
  helm install camunda camunda/camunda-platform \
    -n $NAMESPACE1 --create-namespace \
    -f ./camunda-platform/camunda-platform-core-kind-values.yaml
else
  echo "Camunda is already installed in $NAMESPACE1."
fi

# Wait for Camunda
echo "Waiting for Camunda pods to be created..."
until kubectl get pods -n $NAMESPACE1 2>/dev/null | grep -q "camunda"; do
  echo "Still waiting for Camunda pods..."
  sleep 2
done

echo "Waiting for all Camunda pods to be ready..."
if ! kubectl wait --for=condition=ready pod --all -n $NAMESPACE1 --timeout=400s; then
  echo "ERROR: Timeout waiting for Camunda pods to become ready"
  exit 1
fi

# Install Kafka
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
if ! kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=kafka -n $NAMESPACE1 --timeout=300s; then
  echo "ERROR: Timeout waiting for Kafka pods to become ready"
  exit 1
fi

echo "Execute Kafka topics job..."
kubectl apply -f kafka-service/kafka-topic-job.yaml

echo "Waiting for Kafka topics job to be done..."
if ! kubectl wait --for=condition=complete job/create-kafka-topics -n $NAMESPACE1 --timeout=120s; then
  echo "ERROR: Timeout waiting for Kafka topics job to complete"
  exit 1
fi

echo "Configuring Kafka broker message size limits..."
kubectl run kafka-config-all --rm -it --restart=Never --image=bitnamilegacy/kafka:4.0.0-debian-12-r10 --namespace=proving-system -- bash -c "for broker in 0 1 2; do kafka-configs.sh --bootstrap-server kafka.proving-system.svc.cluster.local:9092 --entity-type brokers --entity-name \$broker --alter --add-config message.max.bytes=52428800; done"

echo "Pulling Docker images from registry..."
docker pull ghcr.io/acp-pcvcf/sensor-data-service:latest
docker pull ghcr.io/acp-pcvcf/camunda-service:latest
docker pull ghcr.io/acp-pcvcf/proving-service:latest
docker pull ghcr.io/acp-pcvcf/verifier:latest
docker pull ghcr.io/acp-pcvcf/pcf-registry:latest
docker pull ghcr.io/acp-pcvcf/sensor-key-registry:latest

echo "Installing PCF-Registry with MinIO via Helm..."
if ! helm list -n $NAMESPACE1 | grep -q pcf-registry; then
  echo "Installing PCF-Registry in namespace $NAMESPACE1..."
  helm upgrade --install pcf-registry ./pcf-registry/pcf-deployment-charts -n $NAMESPACE1
else
  echo "PCF-Registry is already installed in $NAMESPACE1."
fi

echo "Waiting for PCF-Registry pods to be ready..."
if ! kubectl wait --for=condition=ready pod -l app=pcf-registry-service -n $NAMESPACE1 --timeout=300s; then
  echo "ERROR: Timeout waiting for PCF-Registry pods to become ready"
  exit 1
fi

echo "Waiting for MinIO pods to be ready..."
if ! kubectl wait --for=condition=ready pod -l app=minio-server -n $NAMESPACE1 --timeout=300s; then
  echo "ERROR: Timeout waiting for MinIO pods to become ready"
  exit 1
fi

echo "Loading Docker images into kind cluster..."
kind load docker-image ghcr.io/acp-pcvcf/sensor-data-service:latest --name $KIND_CLUSTER_NAME
kind load docker-image ghcr.io/acp-pcvcf/camunda-service:latest --name $KIND_CLUSTER_NAME
kind load docker-image ghcr.io/acp-pcvcf/proving-service:latest --name $KIND_CLUSTER_NAME
kind load docker-image ghcr.io/acp-pcvcf/verifier:latest --name $KIND_CLUSTER_NAME
kind load docker-image ghcr.io/acp-pcvcf/pcf-registry:latest --name $KIND_CLUSTER_NAME
kind load docker-image ghcr.io/acp-pcvcf/sensor-key-registry:latest --name $KIND_CLUSTER_NAME

echo "Deploying services to Kubernetes..."
kubectl apply -f ./sensor-data-service/k8s/sensor-data-service.yaml -n $NAMESPACE1
kubectl apply -f ./camunda-service/k8s/camunda-service.yaml -n $NAMESPACE1
kubectl apply -f ./proving-service/k8s/proving-service.yaml -n $NAMESPACE1
kubectl apply -f ./sensor-key-registry/k8s/sensor-key-registry.yaml -n $NAMESPACE2
kubectl apply -f ./verifier-service/k8s/verifier-service.yaml -n $NAMESPACE2

echo "All services deployed successfully to namespaces '$NAMESPACE1' and '$NAMESPACE2'."
kubectl get pods -n $NAMESPACE1
kubectl get pods -n $NAMESPACE2
