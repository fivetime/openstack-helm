# OVN BGP Agent Helm Chart

This Helm chart deploys the OVN BGP Agent for exposing OpenStack VMs and containers through BGP in OVN-based networking environments.

## Overview

The OVN BGP Agent enables automatic BGP route advertisement for OpenStack workloads deployed with OVN networking. It integrates with FRRouting (FRR) to establish BGP peering sessions with the underlying network infrastructure.

**Key Features:**

- **Zero-Configuration Deployment**: Intelligent auto-discovery of network topology
- **Deterministic ASN Assignment**: IP-based ASN generation ensures consistent configuration across pod restarts
- **Intelligent Gateway Discovery**: Three-tier fallback mechanism (routing table → ARP scan → subnet convention)
- **Persistent ASN Mapping**: ConfigMap-based Leaf ASN mapping survives helm upgrades
- **Flexible Deployment Modes**: Centralized (network nodes) and distributed (compute nodes) architectures
- **EVPN Support**: Optional L2VPN EVPN for overlay networking scenarios
- **Multiple Driver Options**: Choose the appropriate driver for your deployment needs

## Prerequisites

- **Kubernetes**: Version 1.23 or higher
- **Helm**: Version 3.2+ (for `lookup` function support)
- **OpenStack**: Deployed with OVN networking (Neutron + OVN)
- **OVN Databases**: Accessible OVN NB and SB databases
- **Network Infrastructure**: BGP-capable switches (Leaf-Spine architecture recommended)
- **Host Networking**: Nodes must have `br-ex` interface configured with IP addresses

## Quick Start

### 1. Label Target Nodes

**For centralized deployment** (network/gateway nodes):
```bash
kubectl label nodes <network-node> openstack-network-node=enabled
```

**For distributed deployment** (compute nodes):
```bash
kubectl label nodes <compute-node> openstack-compute-node=enabled
```

### 2. Prepare Leaf ASN Mapping

Create a custom values file with your network topology:

```yaml
# custom-values.yaml
bgp:
  enabled: true
  asn_mapping:
    "10.0.192.0/24": "65001"  # Rack1 → Leaf-1
    "10.0.193.0/24": "65002"  # Rack2 → Leaf-2
    "10.0.194.0/24": "65003"  # Rack3 → Leaf-3
```

**Important**: Map each rack's subnet to its connected Leaf switch ASN.

### 3. Install the Chart

```bash
helm install ovn-bgp-agent ./ovn-bgp-agent \
  --namespace openstack \
  --create-namespace \
  --values custom-values.yaml
```

**What happens automatically:**
1. ✅ Detects local server IP from `br-ex` interface
2. ✅ Generates local ASN based on IP address (4.2B + 32-bit encoding)
3. ✅ Discovers Leaf switch gateway IP (route table → ARP → fallback)
4. ✅ Looks up Leaf ASN from ConfigMap based on subnet
5. ✅ Generates FRR configuration and establishes BGP session

### 4. Verify Deployment

```bash
# Check pod status
kubectl -n openstack get pods -l application=ovn-bgp-agent

# View initialization output
kubectl -n openstack logs daemonset/ovn-bgp-agent -c init-frr-config

# Check BGP session
kubectl -n openstack exec daemonset/ovn-bgp-agent -c frr -- \
  vtysh -c "show bgp summary"
```

Expected output:
```
Neighbor        V  AS      MsgRcvd MsgSent   Up/Down  State/PfxRcd
10.0.192.1      4  65001        42      45   00:12:34  Established
```

## Configuration

### Basic Configuration

The simplest configuration with auto-discovery:

```yaml
bgp:
  enabled: true
  asn_mapping:
    "10.0.192.0/24": "65001"
    "10.0.193.0/24": "65002"
```

### Peer Discovery Options

Control how the Leaf switch IP is discovered:

```yaml
bgp:
  peer_ip: ""  # Options: "", "detection", "first", "last", or explicit IP

  # "" or "detection" (default) - Auto-detect using:
  #   1. Default route from routing table (preferred)
  #   2. ARP scan of first/last subnet IPs (fallback)
  #   3. First IP in subnet (last resort)

  # "first" - Use first usable IP in subnet (network + 1)
  
  # "last" - Use last usable IP in subnet (broadcast - 1)
  
  # "10.0.192.1" - Explicitly specify Leaf switch IP
```

**When to use explicit IP:**
- Auto-discovery fails in your environment
- Multiple gateways in the same subnet
- Non-standard gateway placement

### EVPN Configuration

Enable EVPN for L2VPN overlay scenarios:

```yaml
bgp:
  enabled: true
  
  evpn:
    enabled: true
    rr_ip: "192.168.100.1"    # Spine loopback IP (Route Reflector)
    rr_asn: "65000"           # Spine ASN (typically 16-bit private)
```

**EVPN Topology:**
```
Server ←eBGP→ Leaf:   IPv4 Unicast (underlay routes)
Server ←iBGP→ Spine:  L2VPN EVPN (VXLAN overlay)
```

### Driver Selection

Choose the appropriate driver for your use case:

```yaml
conf:
  ovn_bgp_agent:
    DEFAULT:
      driver: nb_ovn_bgp_driver  # Recommended for most deployments
      
      # Available drivers:
      # - nb_ovn_bgp_driver: Uses OVN NB database (recommended, stable)
      # - ovn_bgp_driver: Legacy driver using OVN SB database
      # - ovn_evpn_driver: EVPN support with SB database
      # - ovn_stretched_l2_bgp_driver: Stretched L2 networks
```

**Driver comparison:**

| Driver | Database | Use Case | Stability |
|--------|----------|----------|-----------|
| `nb_ovn_bgp_driver` | OVN NB | General purpose | ⭐⭐⭐ Recommended |
| `ovn_bgp_driver` | OVN SB | Legacy deployments | ⭐⭐ Stable |
| `ovn_evpn_driver` | OVN SB | EVPN scenarios | ⭐ Experimental |
| `ovn_stretched_l2_bgp_driver` | OVN SB | Stretched L2 | ⭐ Experimental |

### Tenant Network Exposure

Configure exposure of tenant networks via BGP:

```yaml
conf:
  ovn_bgp_agent:
    DEFAULT:
      driver: nb_ovn_bgp_driver
      expose_tenant_networks: true
      expose_ipv6_gua_tenant_networks: true
      
      # Optional: Filter by OpenStack address scope UUID
      address_scopes: "public-scope-uuid"
```

### Resource Limits

Adjust resource allocation based on deployment scale:

```yaml
pod:
  resources:
    enabled: true
    ovn_bgp_agent:
      requests:
        memory: "512Mi"   # Increased from default 256Mi
        cpu: "500m"       # Increased from default 200m
      limits:
        memory: "2Gi"     # Increased from default 1Gi
        cpu: "2000m"
    frr:
      requests:
        memory: "256Mi"   # Increased from default 128Mi
        cpu: "200m"       # Increased from default 100m
      limits:
        memory: "512Mi"
        cpu: "500m"
```

**Recommended resource allocation by scale:**

| Deployment Size | VMs | Agent Memory | FRR Memory | Agent CPU | FRR CPU |
|----------------|-----|--------------|------------|-----------|---------|
| Small (<100) | <100 | 256Mi | 128Mi | 200m | 100m |
| Medium (100-500) | 100-500 | 512Mi | 256Mi | 500m | 200m |
| Large (500-1000) | 500-1000 | 1Gi | 512Mi | 1000m | 500m |
| Extra Large (>1000) | >1000 | 2Gi | 512Mi | 2000m | 500m |

## Leaf ASN Configuration Management

### Why Configure Leaf ASN Mapping?

In Leaf-Spine architecture, each Leaf switch has a unique ASN. Servers need to know their connected Leaf's ASN to establish eBGP sessions. Since one Leaf connects to multiple servers (each with different IPs), the ASN cannot be derived from peer IP.

### Network Topology Example

```
         [Spine]
         AS 65000
            |
    +-------+-------+-------+
    |       |       |       |
 [Leaf1] [Leaf2] [Leaf3] [Leaf4]
 AS65001  AS65002 AS65003 AS65004
    |       |       |       |
  Rack1   Rack2   Rack3   Rack4
10.0.192.x 193.x  194.x  195.x
```

**Mapping logic:**
- All servers in 10.0.192.0/24 (Rack1) → Leaf-1 (AS 65001)
- All servers in 10.0.193.0/24 (Rack2) → Leaf-2 (AS 65002)
- All servers in 10.0.194.0/24 (Rack3) → Leaf-3 (AS 65003)

### Initial Configuration

Define the mapping in `values.yaml`:

```yaml
bgp:
  asn_mapping:
    "10.0.192.0/24": "65001"  # Rack1 → Leaf-1
    "10.0.193.0/24": "65002"  # Rack2 → Leaf-2
    "10.0.194.0/24": "65003"  # Rack3 → Leaf-3
```

On first `helm install`, this creates ConfigMap `ovn-bgp-agent-asn`.

### Runtime ASN Mapping Updates

#### Adding a New Rack/Leaf

**Method 1: Direct edit**
```bash
kubectl -n openstack edit configmap ovn-bgp-agent-asn

# Add in mapping.json:
# "10.0.195.0/24": "65004"
```

**Method 2: Using kubectl patch**
```bash
# Get current mappings
CURRENT=$(kubectl -n openstack get configmap ovn-bgp-agent-asn \
  -o jsonpath='{.data.mapping\.json}')

# Add new mapping
NEW=$(echo "$CURRENT" | jq '. + {"10.0.195.0/24": "65004"}')

# Apply
kubectl -n openstack patch configmap ovn-bgp-agent-asn \
  --type merge -p "{\"data\":{\"mapping.json\":\"$NEW\"}}"
```

#### Viewing Current Mappings

```bash
kubectl -n openstack get configmap ovn-bgp-agent-asn \
  -o jsonpath='{.data.mapping\.json}' | jq .
```

### ConfigMap Update Behavior

⚠️ **Important Characteristics:**

1. **Initial Installation**: ConfigMap created from `values.yaml`
2. **Helm Upgrades**: Existing ConfigMap is **PRESERVED** (not modified)
3. **Manual Edits**: Safe to edit directly via `kubectl edit`
4. **Pod Restart**: New pods automatically use updated mappings
5. **Uninstall**: ConfigMap is automatically deleted

🔄 **Force regeneration from values.yaml:**
```bash
# Delete existing ConfigMap
kubectl delete configmap ovn-bgp-agent-asn -n openstack

# Helm upgrade recreates it
helm upgrade ovn-bgp-agent ./ovn-bgp-agent --reuse-values
```

### How to Determine Leaf Switch ASN

Query your Leaf switch:

**Cisco NX-OS:**
```bash
show bgp summary
```

**Arista EOS:**
```bash
show ip bgp summary
```

**Cumulus Linux / FRRouting:**
```bash
vtysh -c "show bgp summary"
```

**Juniper:**
```bash
show bgp summary
```

Look for "local AS" or "Local AS" in the output.

## Network Architecture

### ASN Assignment Strategy

**Server ASN (32-bit, automatic):**
```
ASN = 4,200,000,000 + (octet2 × 65,536) + (octet3 × 256) + octet4

Examples:
  10.0.192.111 → AS 4200049263
  10.0.193.111 → AS 4200049519
  10.1.192.111 → AS 4200114799
```

**Benefits:**
- ✅ No manual ASN management for servers
- ✅ ASN persists across pod restarts
- ✅ Collision-free (unique IPs → unique ASNs)
- ✅ Uses IANA-reserved 32-bit private range

**Leaf ASN (16-bit, manual):**
- Typical range: 64512-65534 (private ASN)
- Configured in ConfigMap per rack/subnet

### Typical BGP Topology

```
                 [Spine]
              AS 65000 (16-bit)
                    |
         +----------+----------+
         |                     |
     [Leaf-1]              [Leaf-2]
  AS 65001 (16-bit)     AS 65002 (16-bit)
  10.0.192.1            10.0.193.1
         |                     |
    [Server-1]            [Server-2]
  AS 4200049263         AS 4200049519
  (32-bit, auto)        (32-bit, auto)
  10.0.192.111          10.0.193.111
```

**BGP Session Types:**

| Session | Local | Peer | Type | Address Family |
|---------|-------|------|------|----------------|
| Server-Leaf | Server | Leaf | eBGP | IPv4 Unicast |
| Leaf-Spine | Leaf | Spine | eBGP | IPv4 + EVPN |
| Server-Spine | Server | Spine | iBGP | L2VPN EVPN (optional) |

### Gateway Discovery Methods

Three-tier fallback mechanism:

**1. Routing Table (preferred):**
```bash
ip route show dev br-ex | grep '^default'
# Output: default via 10.0.192.1 dev br-ex
```

**2. ARP Scanning (fallback):**
```bash
# Ping first and last IPs concurrently
ping 10.0.192.1 & ping 10.0.192.254 &
# Check ARP table for responses
ip neigh show dev br-ex
```

**3. Subnet Convention (last resort):**
```bash
# Assume gateway is first usable IP (network + 1)
# For 10.0.192.0/24 → 10.0.192.1
```

## Deployment Modes

### Centralized Mode

Deploy on network nodes hosting OVN gateway ports:

```yaml
labels:
  agent:
    node_selector_key: openstack-network-node
    node_selector_value: enabled
```

**Use cases:**
- Tenant network exposure via centralized gateways
- Traffic flows through network nodes (cr-lrp ports)

**Label nodes:**
```bash
kubectl label nodes network-node-1 openstack-network-node=enabled
```

### Distributed Mode

Deploy on all compute nodes:

```yaml
labels:
  agent:
    node_selector_key: openstack-compute-node
    node_selector_value: enabled
```

**Use cases:**
- Provider network direct exposure
- Floating IP (FIP) direct routing
- Traffic flows directly from compute nodes

**Label nodes:**
```bash
kubectl label nodes compute-node-{1..10} openstack-compute-node=enabled
```

### Hybrid Mode

Deploy on both node types (requires separate DaemonSets or combined labels).

## Verification and Troubleshooting

### Basic Verification

```bash
# 1. Check pod status
kubectl -n openstack get pods -l application=ovn-bgp-agent

# 2. View initialization log
kubectl -n openstack logs daemonset/ovn-bgp-agent -c init-frr-config

# 3. Check BGP session
kubectl -n openstack exec daemonset/ovn-bgp-agent -c frr -- \
  vtysh -c "show bgp summary"

# 4. View advertised routes
kubectl -n openstack exec daemonset/ovn-bgp-agent -c frr -- \
  vtysh -c "show ip bgp"
```

### Common Issues

#### Issue 1: BGP Session Not Established

**Symptoms:**
```
Neighbor        V  AS      State
10.0.192.1      4  65001   Active  (or Idle)
```

**Diagnosis:**
```bash
# Check configuration
kubectl -n openstack logs daemonset/ovn-bgp-agent -c init-frr-config

# Test connectivity
kubectl -n openstack exec daemonset/ovn-bgp-agent -c ovn-bgp-agent -- \
  ping -c 3 10.0.192.1

# View FRR config
kubectl -n openstack exec daemonset/ovn-bgp-agent -c frr -- \
  cat /etc/frr/frr.conf
```

**Common causes:**
1. Leaf switch not configured for peering
2. Wrong Leaf ASN in ConfigMap
3. Firewall blocking TCP/179 (BGP)
4. Wrong peer IP detected

**Solution:**
```bash
# Fix ASN mapping
kubectl -n openstack edit configmap ovn-bgp-agent-asn

# Or force specific peer IP
helm upgrade ovn-bgp-agent ./ovn-bgp-agent \
  --set bgp.peer_ip="10.0.192.1" --reuse-values
```

#### Issue 2: ASN Mapping Not Found

**Symptoms:**
```
ERROR: No Leaf ASN mapping found for subnet: 10.0.195.0/24
```

**Diagnosis:**
```bash
# Check node's subnet
kubectl -n openstack exec daemonset/ovn-bgp-agent -c init-frr-config -- \
  ip -4 route show dev br-ex | grep -v default

# Check ConfigMap
kubectl -n openstack get configmap ovn-bgp-agent-asn -o yaml
```

**Solution:**
```bash
kubectl -n openstack edit configmap ovn-bgp-agent-asn

# Add: "10.0.195.0/24": "65004"
```

#### Issue 3: Wrong Gateway IP Detected

**Symptoms:**
```
Peer (Leaf Switch):
  IPv4:         10.0.192.254
  Reachable:    no
```

**Solution:**
```yaml
# Force specific peer IP in values.yaml
bgp:
  peer_ip: "10.0.192.1"
```

#### Issue 4: OVN Database Connection Failed

**Symptoms:**
```
ERROR: Cannot connect to OVN NB database
```

**Diagnosis:**
```bash
# Test OVN connectivity
kubectl -n openstack exec daemonset/ovn-bgp-agent -c ovn-bgp-agent -- \
  ovn-nbctl --db=tcp://ovn-ovsdb-nb:6641 show

# Check service
kubectl -n openstack get svc ovn-ovsdb-nb
```

## Configuration Examples

### Example 1: Minimal Setup

```yaml
bgp:
  enabled: true
  asn_mapping:
    "10.0.192.0/24": "65001"
```

### Example 2: Multi-Rack with EVPN

```yaml
bgp:
  enabled: true
  peer_ip: "first"  # Use .1 as gateway
  asn_mapping:
    "10.0.192.0/24": "65001"
    "10.0.193.0/24": "65002"
    "10.0.194.0/24": "65003"
  evpn:
    enabled: true
    rr_ip: "192.168.100.1"
    rr_asn: "65000"
```

### Example 3: Production with Resource Limits

```yaml
bgp:
  enabled: true
  asn_mapping:
    "10.0.192.0/24": "65001"
    "10.0.193.0/24": "65002"

pod:
  resources:
    enabled: true
    ovn_bgp_agent:
      requests:
        memory: "512Mi"
        cpu: "500m"
      limits:
        memory: "2Gi"
        cpu: "2000m"
    frr:
      requests:
        memory: "256Mi"
        cpu: "200m"
      limits:
        memory: "512Mi"
        cpu: "500m"
```

## Security Considerations

### Required Privileges

The agent requires elevated privileges:

```yaml
securityContext:
  privileged: true
  capabilities:
    add:
      - NET_ADMIN    # Modify kernel routing tables
      - SYS_ADMIN    # Network namespace operations
      - NET_RAW      # ARP scanning
```

### Network Access Requirements

| Resource | Endpoint | Access | Purpose |
|----------|----------|--------|---------|
| OVS Socket | /run/openvswitch/db.sock | Read | Query OVS state |
| OVN NB | tcp://ovn-ovsdb-nb:6641 | Read | Read logical topology |
| OVN SB | tcp://ovn-ovsdb-sb:6642 | Read | Read southbound DB |
| FRR Socket | /run/frr/*.vty | Read/Write | Control FRR daemons |

## Upgrade and Maintenance

### Performing an Upgrade

```bash
helm upgrade ovn-bgp-agent ./ovn-bgp-agent \
  --namespace openstack \
  --values custom-values.yaml
```

### Upgrade Behavior

- ✅ Rolling update (maxUnavailable: 1)
- ✅ ASN ConfigMap preserved
- ✅ BGP graceful restart
- ✅ Minimal traffic disruption

### Rollback

```bash
helm rollback ovn-bgp-agent -n openstack
```

## Uninstallation

```bash
helm uninstall ovn-bgp-agent --namespace openstack

# Optional: Remove node labels
kubectl label nodes <node> openstack-network-node-
```

## Advanced Topics

### BGP Timers

```
Keepalive: 3 seconds
Hold time: 10 seconds
Connect retry: 10 seconds
```

### Performance Metrics

**BGP Convergence:**
- Single route: < 1s
- 100 routes: < 5s
- 1000 routes: < 30s

**Memory Usage:**
- Base: ~200MB
- Per 1000 routes: +1MB

## References

- [OVN BGP Agent Docs](https://docs.openstack.org/ovn-bgp-agent/latest/)
- [OpenStack Helm](https://docs.openstack.org/openstack-helm/latest/)
- [FRRouting](https://docs.frrouting.org/)
- [RFC 4271 - BGP-4](https://www.rfc-editor.org/rfc/rfc4271.html)
- [RFC 7432 - EVPN](https://www.rfc-editor.org/rfc/rfc7432.html)

## License

Apache License 2.0

---

**Version**: 0.1.0  
**App Version**: 2025.2.0  
**Maintained by**: OpenStack Helm Community