# Ceph Adapter for Rook

This chart provisions the Kubernetes resources required for OpenStack-Helm
charts to consume storage from Ceph clusters.

## Overview

OpenStack-Helm charts (Cinder, Nova, Glance, etc.) expect certain Kubernetes
resources to be available for connecting to Ceph:

- A **ConfigMap** containing `ceph.conf` with monitor addresses
- A **Secret** containing the Ceph client keyring

This chart creates these resources by supporting three deployment modes:

| Mode | Description | Keyring | Auto-Discovery |
|------|-------------|---------|----------------|
| `provider` | Local Rook-Ceph cluster | admin | ✅ Yes |
| `consumer` | Rook external/consumer cluster | csi-rbd-provisioner | ✅ Yes |
| `external` | Non-Rook Ceph cluster | Manual | ❌ No |

## Installation

### Provider Mode (Default)

```bash
helm upgrade --install ceph-adapter-rook ./ceph-adapter-rook \
  --namespace=openstack \
  --create-namespace \
  --set cluster.namespace=rook-ceph
```

### Consumer Mode

```bash
helm upgrade --install ceph-adapter-rook ./ceph-adapter-rook \
  --namespace=openstack \
  --create-namespace \
  --set cluster.mode=consumer \
  --set cluster.namespace=rook-ceph
```

### External Mode

```bash
# First, create the keyring secret
kubectl -n openstack create secret generic external-ceph-keyring \
  --from-literal=key="AQDxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxQ=="

# Then deploy
helm upgrade --install ceph-adapter-rook ./ceph-adapter-rook \
  --namespace=openstack \
  --create-namespace \
  --set cluster.mode=external \
  --set cluster.mon_host="10.0.0.1:6789,10.0.0.2:6789,10.0.0.3:6789" \
  --set cluster.keyring.secret_ref.name=external-ceph-keyring
```

## Configuration

### Cluster Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `cluster.mode` | Deployment mode: `provider`, `consumer`, or `external` | `provider` |
| `cluster.namespace` | Namespace where Rook-Ceph resources are deployed | `rook-ceph` |
| `cluster.mon_endpoints_configmap` | Rook mon endpoints ConfigMap name | `rook-ceph-mon-endpoints` |
| `cluster.admin_secret` | Rook mon secret (provider mode) | `rook-ceph-mon` |
| `cluster.csi_secret` | Rook CSI provisioner secret (consumer mode) | `rook-csi-rbd-provisioner` |
| `cluster.mon_host` | Ceph monitor addresses (external mode) | `""` |
| `cluster.user` | Ceph user name (external mode) | `admin` |
| `cluster.keyring.key` | Ceph keyring value (external mode) | `""` |
| `cluster.keyring.secret_ref.name` | Existing secret name for keyring | `""` |
| `cluster.keyring.secret_ref.namespace` | Existing secret namespace | `""` |
| `cluster.keyring.secret_ref.key` | Key in existing secret | `key` |

### Output Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `output.secret_name` | Name of the Secret to create for keyring | `pvc-ceph-client-key` |
| `output.configmap_name` | Name of the ConfigMap to create for ceph.conf | `ceph-etc` |

### Additional ceph.conf Settings

```yaml
conf:
  ceph:
    global:
      auth_cluster_required: cephx
      auth_service_required: cephx
      auth_client_required: cephx
    client:
      rbd_cache: "true"
      rbd_cache_size: "134217728"
```

## Deployment Modes

### Provider Mode (Default)

Use when Rook-Ceph is deployed in the same Kubernetes cluster with full
administrative access.

```
┌─────────────────────────────────────────────────────────────┐
│                 Single Kubernetes Cluster                   │
│                                                             │
│  ┌─────────────────┐         ┌─────────────────────────┐   │
│  │   Rook-Ceph     │         │      OpenStack          │   │
│  │   (Provider)    │ ──────► │   (Cinder, Nova, etc.)  │   │
│  │                 │  admin  │                         │   │
│  │  - Mon/OSD/MGR  │ keyring │  - storage-init ✅      │   │
│  └─────────────────┘         └─────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Consumer Mode

Use when connecting to a Rook-Ceph cluster running in another Kubernetes
cluster via Rook's external cluster feature.

```
┌────────────────────────┐         ┌────────────────────────┐
│  Provider K8s Cluster  │         │  Consumer K8s Cluster  │
│                        │         │                        │
│  ┌─────────────────┐   │         │  ┌─────────────────┐   │
│  │   Rook-Ceph     │   │  CSI    │  │   Rook CSI      │   │
│  │   (Full Cluster)│ ◄─┼─────────┼──│   (External)    │   │
│  │                 │   │ keyring │  │                 │   │
│  │  - Mon/OSD/MGR  │   │         │  │  - CSI Driver   │   │
│  └─────────────────┘   │         │  └────────┬────────┘   │
│                        │         │           │            │
│                        │         │  ┌────────▼────────┐   │
│                        │         │  │   OpenStack     │   │
│                        │         │  │                 │   │
│                        │         │  │ - storage-init ❌│   │
│                        │         │  └─────────────────┘   │
└────────────────────────┘         └────────────────────────┘
```

**Important:** OpenStack storage-init jobs must be disabled:
```yaml
manifests:
  job_storage_init: false
  job_backup_storage_init: false
```

### External Mode

Use when connecting to a non-Rook Ceph cluster (cephadm, manual deployment).

```
┌────────────────────────┐         ┌────────────────────────┐
│   External Ceph        │         │   Kubernetes Cluster   │
│   (cephadm/manual)     │         │                        │
│                        │         │  ┌─────────────────┐   │
│  ┌─────────────────┐   │ manual  │  │   OpenStack     │   │
│  │  Ceph Cluster   │ ◄─┼─────────┼──│                 │   │
│  │                 │   │ config  │  │  (No Rook CSI)  │   │
│  │  - Mon/OSD/MGR  │   │         │  │                 │   │
│  └─────────────────┘   │         │  └─────────────────┘   │
└────────────────────────┘         └────────────────────────┘
```

## Output Resources

After deployment, these resources are created in the deployment namespace:

| Resource | Type | Description |
|----------|------|-------------|
| `ceph-etc` | ConfigMap | Contains `ceph.conf` with monitor addresses |
| `pvc-ceph-client-key` | Secret | Contains Ceph client keyring |

## Usage with OpenStack-Helm

### Cinder Configuration

```yaml
ceph_client:
  configmap: ceph-etc
  user_secret_name: pvc-ceph-client-key

conf:
  backends:
    rbd1:
      volume_driver: cinder.volume.drivers.rbd.RBDDriver
      rbd_pool: volumes
      rbd_ceph_conf: "/etc/ceph/ceph.conf"
      rbd_user: admin  # or csi-rbd-provisioner for consumer mode
```

## Troubleshooting

### Verify Resources

```bash
# Check ConfigMap
kubectl -n openstack get configmap ceph-etc -o yaml

# Check Secret
kubectl -n openstack get secret pvc-ceph-client-key

# View ceph.conf
kubectl -n openstack get configmap ceph-etc -o jsonpath='{.data.ceph\.conf}'

# Decode keyring
kubectl -n openstack get secret pvc-ceph-client-key \
  -o jsonpath='{.data.key}' | base64 -d
```

### Check Job Status

```bash
kubectl -n openstack get jobs -l application=ceph
kubectl -n openstack logs job/ceph-adapter-rook-namespace-client-key
kubectl -n openstack logs job/ceph-adapter-rook-namespace-client-ceph-config
```

## License

Licensed under the Apache License, Version 2.0.
