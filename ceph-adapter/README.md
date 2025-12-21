# Ceph Adapter for Rook-Ceph

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

**Features:**
- Auto-discovers mon_host from Rook resources
- Exports admin keyring (full management access)
- Supports OpenStack storage-init jobs (user/pool creation)

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

**Features:**
- Auto-discovers mon_host from imported Rook resources
- Exports CSI provisioner keyring (limited permissions)
- Pools and users must be pre-created on provider

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

**Features:**
- No Rook Operator required
- Manual configuration of mon_host and keyring
- Works with any Ceph cluster

## Installation

### Provider Mode (Default)

```bash
helm upgrade --install ceph-adapter-rook ./ceph-adapter-rook \
  --namespace=openstack \
  --create-namespace
```

### Consumer Mode

```bash
helm upgrade --install ceph-adapter-rook ./ceph-adapter-rook \
  --namespace=openstack \
  --create-namespace \
  --set deployment.mode=consumer
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
  --set deployment.mode=external \
  --set external.mon_host="10.0.0.1:6789,10.0.0.2:6789,10.0.0.3:6789" \
  --set external.keyring.secret_ref.name=external-ceph-keyring
```

## Configuration

### Common Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `deployment.mode` | Deployment mode: `provider`, `consumer`, or `external` | `provider` |
| `output.secret_name` | Name of the Secret to create for keyring | `pvc-ceph-client-key` |
| `output.configmap_name` | Name of the ConfigMap to create for ceph.conf | `ceph-etc` |

### Provider Mode Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `provider.cluster_namespace` | Namespace where Rook-Ceph is deployed | `rook-ceph` |
| `provider.mon_endpoints_configmap` | Rook mon endpoints ConfigMap name | `rook-ceph-mon-endpoints` |
| `provider.admin_secret` | Rook mon secret containing admin keyring | `rook-ceph-mon` |

### Consumer Mode Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `consumer.cluster_namespace` | Namespace where Rook external cluster is deployed | `rook-ceph` |
| `consumer.mon_endpoints_configmap` | Rook mon endpoints ConfigMap name | `rook-ceph-mon-endpoints` |
| `consumer.csi_rbd_provisioner_secret` | Rook CSI provisioner secret name | `rook-csi-rbd-provisioner` |

### External Mode Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `external.mon_host` | Ceph monitor addresses (required) | `""` |
| `external.keyring.key` | Ceph keyring value (direct) | `""` |
| `external.keyring.secret_ref.name` | Existing secret name for keyring | `""` |
| `external.keyring.secret_ref.namespace` | Existing secret namespace | `""` |
| `external.keyring.secret_ref.key` | Key in existing secret | `key` |
| `external.ceph_user` | Ceph user name | `admin` |

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
