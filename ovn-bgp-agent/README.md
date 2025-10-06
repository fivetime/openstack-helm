# OVN BGP Agent Helm Chart

This Helm chart deploys the OVN BGP Agent for exposing OpenStack VMs/containers through BGP in OVN environments.

## Overview

The OVN BGP Agent enables BGP route advertisement for OpenStack workloads in OVN-based deployments. It supports multiple drivers and deployment modes:

- **Centralized**: Deploy on network nodes only (for tenant network exposure via gateway ports)
- **Distributed**: Deploy on all compute nodes (for provider network and FIP exposure)
- **IPv4 and IPv6**: Full dual-stack support with automatic configuration
- **EVPN**: Optional EVPN support for L2VPN overlays

## Prerequisites

- Kubernetes 1.23+
- Helm 3.x
- OpenStack deployed with OVN networking
- OVN NB and SB databases accessible
- Network infrastructure supporting BGP (Leaf-Spine architecture recommended)

## Quick Start

### 1. Label Network Nodes

For centralized deployment (network nodes):
```bash
kubectl -n openstack label nodes <network-node> openstack-network-node=enabled
```

For distributed deployment (all compute nodes):
```bash
kubectl -n openstack label nodes <compute-node> openstack-compute-node=enabled
```

### 2. Install the Chart

```bash
helm install ovn-bgp-agent ./ovn-bgp-agent \
  --namespace openstack \
  --create-namespace
```

That's it! The chart will:
- Auto-detect Leaf switch IP from br-ex network
- Generate ASN based on server IP (32-bit private ASN range)
- Calculate Leaf switch ASN from its IP
- Configure FRR for BGP peering

## Configuration

### Basic BGP Configuration (Auto-discovery)

```yaml
bgp:
  enabled: true
  # All settings auto-detected from br-ex interface
```

This will:
1. Detect local IP from br-ex → Generate local ASN
2. Discover Leaf IP (route table → ARP scan → subnet .1)
3. Calculate Leaf ASN from its IP
4. Configure BGP peering automatically

### Advanced BGP Configuration

```yaml
bgp:
  enabled: true
  
  # Peer IP discovery modes:
  peer_ip: ""           # Auto-detect (default)
  # peer_ip: "first"    # Use first IP in subnet
  # peer_ip: "last"     # Use last IP in subnet
  # peer_ip: "10.0.192.1"  # Fixed IP
  
  peer_asn: ""          # Auto-generate from peer_ip
```

### EVPN Configuration

```yaml
bgp:
  enabled: true
  peer_ip: ""
  
  evpn:
    enabled: true
    rr_ip: "192.168.100.1"    # Route Reflector (Spine loopback)
    rr_asn: "65000"           # RR ASN (16-bit private)
```

### Driver Selection

```yaml
conf:
  ovn_bgp_agent:
    DEFAULT:
      # Driver options:
      driver: nb_ovn_bgp_driver           # Recommended (NB DB)
      # driver: ovn_bgp_driver            # Legacy (SB DB)
      # driver: ovn_evpn_driver           # EVPN support
      # driver: ovn_stretched_l2_bgp_driver  # Stretched L2
```

### Tenant Network Exposure

```yaml
conf:
  ovn_bgp_agent:
    DEFAULT:
      expose_tenant_networks: true
      # Optional: filter by address scopes
      address_scopes: "public-scope-uuid"
```

## Network Architecture

### ASN Assignment Strategy

The chart uses **IP-based deterministic ASN generation**:

```
ASN = 4200000000 + (octet2 * 65536) + (octet3 * 256) + octet4

Examples:
  10.0.192.111 → AS 4200049263  (Server)
  10.0.192.1   → AS 4200049153  (Leaf)
```

Benefits:
- ✅ No manual ASN management
- ✅ Collision-free (unique IPs = unique ASNs)
- ✅ Persistent across pod restarts
- ✅ Works in distributed deployments

### Typical Topology

```
         [Spine]
       AS 65000 (16-bit)
            |
      +-----+-----+
      |           |
   [Leaf1]    [Leaf2]
AS 4200049153  AS 4200049409 (32-bit, IP-based)
      |           |
  [Server1]   [Server2]
AS 4200049263  AS 4200049469 (32-bit, IP-based)
```

### Peer Discovery Methods

The chart attempts multiple methods to discover the Leaf switch IP:

1. **Route Table** (preferred): `ip route show dev br-ex | grep default`
2. **ARP Scanning**: Ping first/last IP and check ARP table
3. **Subnet Convention** (fallback): Assume gateway is .1

## Deployment Modes

### Centralized (Network Nodes Only)

For tenant networks without FIPs:

```yaml
labels:
  agent:
    node_selector_key: openstack-network-node
    node_selector_value: enabled
```

Deploy on nodes hosting OVN gateway ports (cr-lrp).

### Distributed (All Compute Nodes)

For provider networks and FIPs:

```yaml
labels:
  agent:
    node_selector_key: openstack-compute-node
    node_selector_value: enabled
```

Deploy on all nodes running VMs.

### Hybrid (Both)

Deploy on both network and compute nodes using pod affinity rules.

## Verification

### Check Pod Status

```bash
kubectl -n openstack get pods -l application=ovn-bgp-agent
kubectl -n openstack logs daemonset/ovn-bgp-agent -c ovn-bgp-agent
```

### Verify BGP Session

```bash
# Check FRR BGP status
kubectl -n openstack exec daemonset/ovn-bgp-agent -c frr -- \
  vtysh -c "show bgp summary"

# Expected output:
# Neighbor        V  AS      MsgRcvd MsgSent   Up/Down  State
# 10.0.192.1      4  4200049153  123    456   01:23:45  Established
```

### Check Routes

```bash
# View advertised routes
kubectl -n openstack exec daemonset/ovn-bgp-agent -c frr -- \
  vtysh -c "show ip bgp neighbors 10.0.192.1 advertised-routes"

# View received routes
kubectl -n openstack exec daemonset/ovn-bgp-agent -c frr -- \
  vtysh -c "show ip bgp neighbors 10.0.192.1 routes"
```

## Troubleshooting

### BGP Session Not Established

```bash
# Check configuration
kubectl -n openstack exec daemonset/ovn-bgp-agent -c ovn-bgp-agent -- \
  cat /tmp/bgp-config.log

# Verify Leaf reachability
kubectl -n openstack exec daemonset/ovn-bgp-agent -c ovn-bgp-agent -- \
  ping -c 3 10.0.192.1

# Check FRR logs
kubectl -n openstack logs daemonset/ovn-bgp-agent -c frr
```

### Wrong Peer IP Detected

Override with manual configuration:

```yaml
bgp:
  peer_ip: "10.0.192.1"  # Force specific Leaf IP
```

### ASN Conflicts

If you have IP overlaps across different networks, manually assign ASNs:

```yaml
bgp:
  local_asn: "4200000100"
  peer_asn: "4200000001"
```

### Agent Can't Access OVN Databases

```bash
# Test OVN connectivity
kubectl -n openstack exec daemonset/ovn-bgp-agent -c ovn-bgp-agent -- \
  curl -v tcp://ovn-ovsdb-nb.openstack.svc.cluster.local:6641
```

Check network policies and firewall rules.

## Configuration Examples

### Example 1: Simple Deployment (Auto Everything)

```yaml
bgp:
  enabled: true
```

### Example 2: Fixed Leaf IP

```yaml
bgp:
  enabled: true
  peer_ip: "10.0.192.1"
```

### Example 3: EVPN with Route Reflector

```yaml
bgp:
  enabled: true
  peer_ip: "10.0.192.1"
  evpn:
    enabled: true
    rr_ip: "192.168.100.1"
    rr_asn: "65000"
```

### Example 4: Tenant Networks Only

```yaml
conf:
  ovn_bgp_agent:
    DEFAULT:
      driver: nb_ovn_bgp_driver
      expose_tenant_networks: true
      address_scopes: "public-scope-uuid"

bgp:
  enabled: true
```

### Example 5: Production with Resource Limits

```yaml
bgp:
  enabled: true

pod:
  resources:
    enabled: true
    ovn_bgp_agent:
      requests:
        memory: "256Mi"
        cpu: "200m"
      limits:
        memory: "2Gi"
        cpu: "2000m"
    frr:
      requests:
        memory: "128Mi"
        cpu: "100m"
      limits:
        memory: "512Mi"
        cpu: "500m"
```

## Resource Requirements

### Minimum

- Memory: 256Mi per container
- CPU: 100m per container

### Recommended

- Memory: 512Mi (agent) + 256Mi (FRR)
- CPU: 500m (agent) + 200m (FRR)

### Large Deployments (1000+ VMs)

- Memory: 2Gi (agent) + 512Mi (FRR)
- CPU: 2000m (agent) + 500m (FRR)

## Security Considerations

The agent requires privileged access:

```yaml
securityContext:
  privileged: true
  capabilities:
    add: [NET_ADMIN, SYS_ADMIN, NET_RAW]
```

This is necessary for:
- Kernel routing manipulation (ip rules, routes)
- OVS flow management
- Network namespace operations

## Upgrading

```bash
helm upgrade ovn-bgp-agent ./ovn-bgp-agent \
  --namespace openstack \
  --values custom-values.yaml
```

The chart uses `RollingUpdate` strategy with `maxUnavailable: 1` to minimize disruption.

## Uninstallation

```bash
helm uninstall ovn-bgp-agent --namespace openstack
```

BGP sessions will be terminated gracefully, and routes will be withdrawn.

## Contributing

To contribute to this chart:

1. Fork the openstack-helm repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request to https://opendev.org/openstack/openstack-helm

## References

- [OVN BGP Agent Documentation](https://docs.openstack.org/ovn-bgp-agent/latest/)
- [OpenStack Helm Documentation](https://docs.openstack.org/openstack-helm/latest/)
- [FRRouting Documentation](https://docs.frrouting.org/)
- [BGP Best Practices](https://www.rfc-editor.org/rfc/rfc7938.html)

## License

Licensed under the Apache License, Version 2.0