# ovn-ic-central

OpenStack-Helm chart for **ovn-ic-central** — the external orchestrator that
drives native **OVN Interconnection** (Transit Switch / Transit Router)
*beneath* Neutron. It is the control plane that sits on top of the `ovn-ic`
chart's plumbing: it reconciles a declared set of interconnections into native
OVN-IC objects (`ovn-ic-nbctl tr-add`/`ts-add`, transit ports, routes) and
tags everything `ovnic:*` so it never touches Neutron-owned objects.

Requires OVN **>= 26.03** (Transit Router) on every participating AZ. The image
(`ghcr.io/fivetime/openstackhelm/ovn-ic-central`) is the `ovn` image plus the
ovn-ic-central Python package, so it ships the 26.03 `ovn-ic-nbctl`/`-sbctl`.

## What it is (and is not)

- It is a **pure TCP client**: no host mounts, no privileges. It connects to
  this AZ's local OVN NB/SB and to the global IC NB/SB.
- It does **not** run the `ovn-ic` daemon — the `ovn-ic` chart's agent does.
  Here `[ovnic] ovn_ic_daemon_ctl = /bin/true` (a no-op), so the orchestrator
  only issues CLI/IDL operations and reconciles.
- Deploy **one release per AZ** (`[ovnic] az_name` unique per AZ).

## Deploy

The four OVN connection strings are derived from `endpoints`
(`ovn_ovsdb_nb`/`_sb` = this AZ's local OVN; `ovn_ic_nb`/`_sb` = the hub), so a
minimal install only needs the per-AZ identity and the coexistence assertion:

    helm install ovn-ic-central ./ovn-ic-central --namespace openstack \
      --set conf.ovn_ic_central.ovnic.az_name=az1 \
      --set conf.ovn_ic_central.ovnic.coexistence_verified=true \
      --set conf.ovn_ic_central.ovnic.gateway_chassis=chassis-a

If the local OVN or the IC hub live in another namespace, set
`endpoints.<ep>.namespace` / `host_fqdn_override` accordingly.

## Required / notable config (`conf.ovn_ic_central.ovnic`)

- **`az_name`** (default `az1`) — globally-unique AZ name; **must equal** this
  AZ's `NB_Global.name` (what the `ovn` chart registers). A mismatch registers
  the AZ under the wrong name in IC-SB.
- **`coexistence_verified`** (default `false`, **fail-closed**) — the agent
  refuses to provision until the operator asserts the local Neutron ML2/OVN
  has the coexistence hardening (so `db-sync` won't delete `ovnic:*` objects).
  Set `true` once verified.
- **`mode`** (`auto`/`tr`/`ts`) — `auto` picks Transit Router when every AZ is
  OVN ≥ 26.03, else falls back to Transit Switch.
- **`gateway_chassis`** — ordered chassis list eligible to host an
  interconnection's distributed gateway port (first reachable = active, rest =
  HA). The order is **respected as given** (no rotation).
- **`interconnections_file`** — the desired-state file the reconcile loop reads
  each cycle (seeded to `[]` on an emptyDir). Edit it, or enable the REST API
  (`enable_rest_api`), to declare interconnections.

## Notes

- **HA — single active per AZ (active-passive):** the agent is a *stateless*
  reconciler, so the default `pod.replicas.agent: 2` is 1 active + 1 hot standby
  (soft anti-affinity spreads them across nodes). The replicas elect one active
  by holding an **ovsdb-lock** on the local NB
  (`conf.ovn_ic_central.ovnic.ha_lock_name`); only the lock holder reconciles,
  the standby waits and takes over on leader loss. It is **not** active-active
  and cannot be: every replica drives the *same* shared OVN-NB / IC-NB / IC-SB,
  so concurrent writers would issue duplicate, conflicting `ovn-ic-nbctl` ops —
  the lock serialises them to a single writer (the same single-active lock model
  the `ovn` chart uses for northd). It is lock-based, **not RAFT**, so 2 replicas
  suffice — no quorum / odd count needed. Raise for extra standbys, or set
  `pod.replicas.agent: 1` to rely on k8s rescheduling (a brief reconcile gap,
  harmless since reconcile is periodic and idempotent).
  - The ovsdb-lock only advances under the image's oslo.service **threading**
    backend; if yours lacks it, set `conf.ovn_ic_central.ovnic.ha_backend=tooz`
    (+ `tooz_backend_url` to etcd/redis), or drop to `pod.replicas.agent: 1`
    with `ha_lock_name: ""` (no lock — safe only single-replica).
  - The desired-state file is **per-pod** (emptyDir by default). With >1 replica
    a `ReadWriteOnce` PVC won't attach to every pod — use a RWX volume or drive
    desired state from a durable external source (REST API / config) so a
    standby that becomes leader doesn't reconcile against an empty list.
- **Metrics:** set `monitoring.enabled=true` to turn on the agent's built-in
  Prometheus endpoint (`[ovnic] enable_metrics`), expose the container port +
  `prometheus.io` pod annotations, and create the headless
  `ovn-ic-central-metrics` Service (port `conf.ovn_ic_central.ovnic.metrics_port`,
  default 9105). Only the active leader emits live counters.
- **Plumbing is separate:** this chart is the orchestrator. The OVN-IC
  databases + per-AZ `ovn-ic` daemon are the `ovn-ic` chart; the local OVN is
  the `ovn` chart. Deploy those first.
- **Desired state is the source of truth:** the agent only ADDs to Neutron
  routers and only ever creates/deletes its own `ovnic:*` objects.
