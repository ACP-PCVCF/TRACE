# TRACE System Setup Instructions

This guide will walk you through setting up the TRACE integration system from scratch. The system consists of multiple microservices that work together to provide a complete tracing and verification platform.

## Prerequisites

Before starting the setup, ensure you have the following tools installed on your system:

- **Docker** - Container runtime for building and running services
- **Minikube** or **Kind** - Local Kubernetes cluster
- **kubectl** - Kubernetes command-line tool
- **Helm** - Kubernetes package manager
- **Git** - Version control system
- **Bash shell** - For running setup scripts
- **Camunda Modeler (Camunda 8)** - Desktop application to deploy BPMN/DMN models.
  - Download: https://camunda.com/download/modeler/ or https://github.com/camunda/camunda-modeler/releases

## Initial System Setup

### 1. Clone the Repository

First, clone the integration repository to your local machine:

```bash
git clone https://github.com/ACP-PCVCF/TRACE.git
cd TRACE
```

### 2. Start the Cluster and Deploy Services

Choose your preferred Kubernetes cluster and deployment method:

#### Helm Chart Deployments

**For Minikube with Helm Charts:**
```bash
chmod +x ./scripts/minikube/setup-helm.sh
./scripts/minikube/setup-helm.sh
```

**For Kind with Helm Charts:**
```bash
chmod +x ./scripts/kind/setup-helm.sh
./scripts/kind/setup-helm.sh
```

These setup scripts will perform the following operations:
- Start your Kubernetes cluster (Minikube/Kind)
- Create namespaces (`proving-system` and `verifier-system`)
- Add Helm repositories (Camunda and Bitnami)
- Install Camunda Platform
- Install Kafka messaging system
- Configure Kafka topics and message size limits
- Pull latest Docker images from registry
- Deploy all TRACE services to appropriate namespaces

**Alternative: Kubernetes Manifest Deployment**

You can also use the standard Kubernetes manifest deployment scripts:
- `./scripts/kind/setup.sh` for Kind clusters
- `./scripts/minikube/setup.sh` for Minikube clusters

**Note:** Even with manifest deployments, Helm is still required for installing Kafka and Camunda Platform components.

### 3. Configure Port Forwarding

After the cluster is running, you need to set up port forwarding to access the services from your local machine.

#### Camunda Gateway (Required for Modeler)

Forward the Zeebe gateway port to connect Camunda Modeler:

```bash
kubectl port-forward svc/camunda-zeebe-gateway 26500:26500 -n proving-system
```

**Important:** Keep this terminal session open while working with Camunda Modeler.

#### Camunda Operate (Process Management)

Forward the Camunda Operate service to view and manage process instances:

```bash
kubectl port-forward svc/camunda-operate 8081:80 -n proving-system
```

Access Camunda Operate at: http://localhost:8081
- Username: `demo`
- Password: `demo`

## BPMN Model Deployment

### 1. Configure Camunda Modeler

In the Camunda Modeler application:

1. Open your BPMN files for e.g. in `camunda-service/data/bpmn`:
   - `Origin.bpmn`
   - `tsp.bpmn`
   - `Amazing Company 1.bpmn`
   - `Amazing Company 2.bpmn`
   - `Amazing Company 3.bpmn`

2. Select **Camunda 8 → Self-Managed**

3. Configure connection settings:
   - **Zeebe Gateway Address:** `localhost:26500`
   - **Authentication:** None

### 2. Deploy and Start Processes

1. Click **Deploy Current Diagram** in Camunda Modeler
2. Start the process (`Origin.bpmn`) in Camunda Modeler
3. Monitor progress in Camunda Operate (http://localhost:8081/operate)

## Verification and Monitoring

### Check Service Status

Verify all services are running correctly:

```bash
# Check pods in proving-system namespace
kubectl get pods -n proving-system

# Check pods in verifier-system namespace
kubectl get pods -n verifier-system
```

### Monitor Service Logs

View logs for individual services:

```bash
# Camunda service logs
kubectl logs deployment/camunda-service -n proving-system

# Sensor data service logs
kubectl logs deployment/sensor-data-service -n proving-system

# Proving service logs
kubectl logs deployment/proving-service -n proving-system

# PCF registry service logs
kubectl logs deployment/pcf-registry-service -n proving-system

# Verifier service logs
kubectl logs deployment/verifier-service -n verifier-system

# Sensor key registry service logs
kubectl logs deployment/sensor-key-registry -n verifier-system
```


For information on updating services and maintaining your installation, see the [Update Instructions](./update-instructions.md) documentation.
