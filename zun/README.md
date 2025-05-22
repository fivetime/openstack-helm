# OpenStack Zun Helm Chart

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.24+-blue.svg)](https://kubernetes.io/)
[![OpenStack](https://img.shields.io/badge/OpenStack-2025.1-red.svg)](https://www.openstack.org/)

OpenStack Zun Container Service deployment on Kubernetes using Helm.

## Overview

Zun is OpenStack's Container-as-a-Service project that provides an API service for running application containers without requiring end users to manage servers or clusters. This Helm chart deploys a complete Zun service stack on Kubernetes, integrating seamlessly with existing OpenStack deployments.

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Zun API       │    │  Zun WebSocket  │    │   Zun Compute   │
│  (Deployment)   │    │     Proxy       │    │  (DaemonSet)    │
│                 │    │  (Deployment)   │    │                 │
│ • REST API      │    │ • Console Access│    │ • Docker Mgmt   │
│ • Auth & Policy │    │ • WebSocket     │    │ • Privileged    │
│ • Scheduling    │    │ • Terminal      │    │ • Host Network  │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────┬───────────┴───────────┬───────────┘
                     │                       │
            ┌─────────────────┐    ┌─────────────────────┐
            │  Zun CNI Daemon │    │   OpenStack Core    │
            │   (DaemonSet)   │    │                     │
            │                 │    │ • Keystone (Auth)   │
            │ • Network Mgmt  │    │ • Neutron (Network) │
            │ • CNI Plugins   │    │ • Glance (Images)   │
            │ • Privileged    │    │ • Cinder (Storage)  │
            └─────────────────┘    └─────────────────────┘
```

## Features

- **Complete Zun Stack**: API, Compute, CNI Daemon, and WebSocket Proxy
- **OpenStack Integration**: Seamless integration with Keystone, Neutron, Glance, and Cinder
- **High Availability**: Multi-replica API services with PodDisruptionBudgets
- **Security**: RBAC, secrets management, and privileged container isolation
- **Networking**: Kuryr-libnetwork integration for OpenStack networking
- **Monitoring**: Comprehensive logging and metrics collection
- **Upgrades**: Rolling updates with zero-downtime deployments

## Prerequisites

### Kubernetes Cluster
- Kubernetes 1.24+
- Container runtime: Docker (required for Zun Compute)
- CNI plugins installed on compute nodes
- Privileged containers support enabled

### OpenStack Services
- **Keystone**: Identity and authentication service
- **Neutron**: Network service (with Kuryr recommended)
- **Glance**: Image service for container images
- **MariaDB/MySQL**: Database backend
- **RabbitMQ**: Message queue service
- **Memcached**: Caching service

### Node Requirements
- **Control Plane Nodes**: For API and WebSocket Proxy services
- **Compute Nodes**:
   - Docker runtime installed and running
   - CNI plugins in `/opt/cni/bin/`
   - Sufficient resources for container workloads

## Installation

### Quick Start

1. **Add OpenStack Helm Repository**:
   ```bash
   helm repo add openstack-helm https://tarballs.opendev.org/openstack/openstack-helm/
   helm repo update
   ```

2. **Install Helm Toolkit** (required dependency):
   ```bash
   helm install helm-toolkit openstack-helm/helm-toolkit --namespace=openstack-helm-toolkit
   ```

3. **Label Compute Nodes**:
   ```bash
   kubectl label nodes <compute-node-1> openstack-compute-node=enabled
   kubectl label nodes <compute-node-2> openstack-compute-node=enabled
   ```

4. **Install Zun**:
   ```bash
   helm install zun ./zun --namespace=openstack \
     --set endpoints.identity.auth.admin.password=<keystone-admin-password> \
     --set endpoints.identity.auth.zun.password=<zun-service-password> \
     --set endpoints.oslo_db.auth.admin.password=<db-admin-password> \
     --set endpoints.oslo_db.auth.zun.password=<zun-db-password> \
     --set endpoints.oslo_messaging.auth.admin.password=<rabbitmq-admin-password> \
     --set endpoints.oslo_messaging.auth.zun.password=<zun-rabbitmq-password>
   ```

### Custom Installation

1. **Create custom values file**:
   ```bash
   cp values.yaml zun-custom-values.yaml
   ```

2. **Edit configuration** (see [Configuration](#configuration) section)

3. **Install with custom values**:
   ```bash
   helm install zun ./zun -f zun-custom-values.yaml --namespace=openstack
   ```

## Configuration

### Node Placement

Configure where services run using node selectors:

```yaml
labels:
  api:
    node_selector_key: openstack-control-plane
    node_selector_value: enabled
  compute:
    node_selector_key: openstack-compute-node
    node_selector_value: enabled
  cni_daemon:
    node_selector_key: openstack-compute-node
    node_selector_value: enabled
```

### Resource Limits

Adjust resource allocation based on your environment:

```yaml
pod:
  resources:
    api:
      requests:
        memory: "256Mi"
        cpu: "500m"
      limits:
        memory: "1024Mi"
        cpu: "2000m"
    compute:
      requests:
        memory: "512Mi"
        cpu: "1000m"
      limits:
        memory: "2048Mi"
        cpu: "4000m"
```

### Network Configuration

Configure ingress and networking:

```yaml
network:
  container:
    ingress:
      public: true
      classes:
        namespace: "nginx"
        cluster: "nginx-cluster"
  websocket_proxy:
    ingress:
      public: true
      annotations:
        nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
        nginx.ingress.kubernetes.io/upgrade-header: "websocket"
```

### OpenStack Integration

Configure service endpoints and authentication:

```yaml
endpoints:
  identity:
    hosts:
      default: keystone
      internal: keystone-api
    auth:
      zun:
        username: zun
        password: <password>
        project_name: service
  oslo_db:
    hosts:
      default: mariadb
    auth:
      zun:
        username: zun
        password: <password>
```

## Usage

### Basic Operations

1. **List Container Services**:
   ```bash
   openstack container service list
   ```

2. **Create a Container**:
   ```bash
   openstack appcontainer create \
     --name my-container \
     --image cirros \
     --cpu 0.1 \
     --memory 128
   ```

3. **List Containers**:
   ```bash
   openstack appcontainer list
   ```

4. **Execute Commands**:
   ```bash
   openstack appcontainer exec my-container -- /bin/sh
   ```

5. **View Container Logs**:
   ```bash
   openstack appcontainer logs my-container
   ```

### Advanced Features

1. **Container with Networking**:
   ```bash
   openstack appcontainer create \
     --name web-container \
     --image nginx \
     --net network=private-net \
     --port 80:8080
   ```

2. **Container with Storage**:
   ```bash
   openstack appcontainer create \
     --name data-container \
     --image postgres \
     --mount source=data-volume,destination=/var/lib/postgresql/data
   ```

## Monitoring and Troubleshooting

### Health Checks

```bash
# Check pod status
kubectl get pods -n openstack -l application=zun

# Verify services
kubectl get svc -n openstack -l application=zun

# Check ingress
kubectl get ingress -n openstack -l application=zun
```

### Logging

```bash
# API service logs
kubectl logs -n openstack -l component=api -c zun-api

# Compute service logs
kubectl logs -n openstack -l component=compute -c zun-compute

# CNI daemon logs
kubectl logs -n openstack -l component=cni-daemon -c zun-cni-daemon
```

### Common Issues

1. **Docker Access Issues**:
   ```bash
   # Verify Docker socket access
   kubectl exec -n openstack -it <compute-pod> -- docker version
   
   # Check user groups
   kubectl exec -n openstack -it <compute-pod> -- groups zun
   ```

2. **Network Connectivity**:
   ```bash
   # Test API connectivity
   kubectl exec -n openstack -it <test-pod> -- curl http://zun-api:9517/
   
   # Check CNI configuration
   kubectl exec -n openstack -it <cni-pod> -- ls -la /etc/cni/net.d/
   ```

3. **Database Connectivity**:
   ```bash
   # Check database connection
   kubectl logs -n openstack -l job-name=zun-db-sync
   ```

## Upgrading

### Rolling Updates

```bash
# Update with new values
helm upgrade zun ./zun -f zun-custom-values.yaml --namespace=openstack

# Check rollout status
kubectl rollout status deployment/zun-api -n openstack
kubectl rollout status daemonset/zun-compute -n openstack
```

### Version Compatibility

| Zun Chart Version | OpenStack Release | Kubernetes Version |
|-------------------|-------------------|--------------------|
| 2025.1.x          | 2025.1 (Dalmatian)| 1.24+             |

## Security Considerations

### Privileged Containers

Zun Compute and CNI Daemon run as privileged containers with access to:
- Docker socket (`/var/run/docker.sock`)
- Host network and PID namespace
- Device directories (`/dev`)
- Host file systems

**Security Measures:**
- Use dedicated compute nodes
- Implement Pod Security Standards
- Regular security updates
- Network segmentation
- RBAC policies

### Secrets Management

All sensitive data is stored in Kubernetes Secrets:
- Database credentials
- Service account passwords
- TLS certificates
- Authentication tokens

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Commit changes: `git commit -m 'Add amazing feature'`
4. Push to branch: `git push origin feature/amazing-feature`
5. Open a Pull Request

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Support

- **Documentation**: [OpenStack Zun Docs](https://docs.openstack.org/zun/latest/)
- **Community**: [OpenStack Discuss](https://lists.openstack.org/cgi-bin/mailman/listinfo/openstack-discuss)
- **Issues**: [OpenStack Storyboard](https://storyboard.openstack.org/#!/project/openstack/zun)
- **IRC**: `#openstack-zun` on OFTC

## Acknowledgments

- OpenStack Zun Team
- OpenStack Helm Community
- Kubernetes Community

---

**Note**: This chart is designed for production use but requires proper configuration and security hardening based on your specific environment and requirements.