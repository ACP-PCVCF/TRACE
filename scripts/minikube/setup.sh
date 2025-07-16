#!/bin/bash
set -e

NAMESPACE1="proving-system"
NAMESPACE2="verifier-system"

echo "Checking if Minikube is running..."
if ! minikube status | grep -q "Running"; then
  echo "Starting Minikube..."
  minikube start --memory=8192 --cpus=4 --driver=docker
else
  echo "Minikube is already running."
fi

echo "Switching to Minikube Docker context..."
eval "$(minikube docker-env)"

echo "Checking if Camunda Helm repo is added..."
if ! helm repo list | grep -q camunda; then
  echo "Adding Camunda Helm repo..."
  helm repo add camunda https://helm.camunda.io
else
  echo "Camunda Helm repo already added."
fi

echo "Checking if Bitnami Helm repo is added..."
if ! helm repo list | grep -q bitnami; then
  echo "Adding Bitnami Helm repo..."
  helm repo add bitnami https://charts.bitnami.com/bitnami
else
  echo "Bitnami Helm repo already added."
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

echo "Checking if Camunda is already installed..."
if ! helm list -n $NAMESPACE1 | grep -q camunda; then
  echo "Installing Camunda in NAMESPACE1 $NAMESPACE1..."
  helm install camunda camunda/camunda-platform \
    -n $NAMESPACE1 --create-namespace \
    -f ./camunda-platform/camunda-platform-core-kind-values.yaml
else
  echo "Camunda is already installed in $NAMESPACE1."
fi

echo "Waiting for Camunda pods to be created..."
until kubectl get pods -n $NAMESPACE1 2>/dev/null | grep -q "camunda"; do
  echo "Still waiting for Camunda pods..."
  sleep 2
done

echo "Waiting for all Camunda pods to be ready..."
if ! kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=camunda-platform -n $NAMESPACE1 --timeout=400s; then
  echo "ERROR: Timeout waiting for Camunda pods to become ready"
  exit 1
fi

echo "Checking if Kafka is already installed..."
if ! helm list -n $NAMESPACE1 | grep -q kafka; then
  echo "Installing Kafka in NAMESPACE1 $NAMESPACE1..."
  helm install kafka bitnami/kafka \
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

echo "Building Docker images..."
docker build -t sensor-data-service:latest ./sensor-data-service 
docker build -t camunda-service:latest ./camunda-service
docker build --platform=linux/amd64 -t proving-service:latest ./proving-service
docker build -t verifier-service:latest ./verifier-service
docker build -t pcf-registry:latest ./pcf-registry
docker build -t sensor-key-registry:latest ./sensor-key-registry

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

echo "Deploying services to Kubernetes..."
kubectl apply -f ./sensor-data-service/k8s/sensor-data-service.yaml -n $NAMESPACE1
kubectl apply -f ./camunda-service/k8s/camunda-service.yaml -n $NAMESPACE1
kubectl apply -f ./proving-service/k8s/proving-service.yaml -n $NAMESPACE1
kubectl apply -f ./sensor-key-registry/k8s/sensor-key-registry.yaml -n $NAMESPACE2
kubectl apply -f ./verifier-service/k8s/verifier-service.yaml -n $NAMESPACE2

echo "All services deployed successfully to namespaces '$NAMESPACE1' and '$NAMESPACE2'."
kubectl get pods -n $NAMESPACE1
kubectl get pods -n $NAMESPACE2
