# ovn-ic

OpenStack-Helm chart for **OVN Interconnection (OVN-IC)** — native cross-AZ /
cross-cluster L3 interconnection *beneath* Neutron. Companion to the `ovn`
chart; requires OVN **>= 26.03** (Transit Router). The image is the same OVN
image the `ovn` chart uses (it already ships `ovn-ic` + the IC schemas).

## Two roles (toggled in `manifests:`)

The chart serves two distinct deployment scopes; install the relevant half per
release via the `manifests:` switches.

### hub — the global Interconnection databases (deploy ONCE)

`statefulset_ovn_ovsdb_ic_nb` / `_ic_sb` + `service_*` deploy the **shared**
IC-NB / IC-SB databases (`ovsdb-server` on the `ovn-ic-nb/sb` schemas, ports
**6645 / 6646**). There is exactly **one** hub for the whole interconnection
fabric — install it once (a designated cluster/namespace), not per AZ.

    helm install ovn-ic-hub ./ovn-ic --namespace openstack \
      --set manifests.deployment_ovn_ic=false

### agent — the per-AZ `ovn-ic` daemon (deploy in EACH AZ)

`deployment_ovn_ic` runs this AZ's `ovn-ic` daemon: it syncs the AZ's local
OVN NB/SB with the global IC databases (mirrors transit datapaths into the
local NB, advertises/learns routes, registers the AZ). Install it in every AZ,
pointing it at that AZ's local NB/SB and at the (shared) hub:

    helm install ovn-ic-agent ./ovn-ic --namespace openstack \
      --set manifests.statefulset_ovn_ovsdb_ic_nb=false \
      --set manifests.statefulset_ovn_ovsdb_ic_sb=false \
      --set manifests.service_ovn_ovsdb_ic_nb=false \
      --set manifests.service_ovn_ovsdb_ic_sb=false

The agent reads four `endpoints`: `ovn_ovsdb_nb` / `ovn_ovsdb_sb` (this AZ's
local OVN, owned by the `ovn` release) and `ovn_ic_nb` / `ovn_ic_sb` (the hub
— set `host_fqdn_override`/namespace if the hub is in another namespace/AZ).

## Notes

- **AZ name:** OVN-IC registers an AZ by `NB_Global.name`. The `ovn` chart's
  `ovnkube.sh nb-ovsdb` sets it from the node zone; ensure that equals your
  intended AZ name (or have your orchestrator own it). Mismatches mean the AZ
  registers under the wrong name.
- **Geneve only:** OVN-IC does not support VXLAN tunnelling (the `ovn` chart
  already defaults `ovn_encap_type: geneve`).
- **IC databases are standalone** (single-replica) in this chart; RAFT/HA for
  the IC databases is a follow-up (mirroring the `ovn` chart's `*-ovsdb-raft`).
- **Orchestration is separate:** this chart is the OVN-IC *plumbing*. The
  orchestrator that drives interconnections (e.g. `ovn-ic-central`) is its own
  chart/deployment and consumes this plumbing.
