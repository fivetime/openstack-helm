# neutron-ovnic

OpenStack-Helm chart for **neutron-ovnic** — the external orchestrator that
drives native **OVN Interconnection** (Transit Switch / Transit Router)
*beneath* Neutron. It is the control plane that sits on top of the `ovn-ic`
chart's plumbing: it reconciles a declared set of interconnections into native
OVN-IC objects (`ovn-ic-nbctl tr-add`/`ts-add`, transit ports, routes) and
tags everything `ovnic:*` so it never touches Neutron-owned objects.

Requires OVN **>= 26.03** (Transit Router) on every participating AZ. The image
(`ghcr.io/fivetime/openstackhelm/neutron-ovnic`) is the `ovn` image plus the
neutron-ovnic Python package, so it ships the 26.03 `ovn-ic-nbctl`/`-sbctl`.

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

    helm install neutron-ovnic ./neutron-ovnic --namespace openstack \
      --set conf.neutron_ovnic.ovnic.az_name=az1 \
      --set conf.neutron_ovnic.ovnic.coexistence_verified=true \
      --set conf.neutron_ovnic.ovnic.gateway_chassis=chassis-a

If the local OVN or the IC hub live in another namespace, set
`endpoints.<ep>.namespace` / `host_fqdn_override` accordingly.

## Required / notable config (`conf.neutron_ovnic.ovnic`)

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

- **Single active per AZ:** with `pod.replicas.agent: 1` the agent runs without
  an OVSDB lock (`ha_lock_name=""`) — a node reboot can't split-brain. For HA,
  raise replicas **and** set a non-empty `ha_lock_name` (ovsdb-lock) or
  `ha_backend=tooz`. (The shipped image's oslo.service has no threading
  backend, so ovsdb-lock single-active is reliable only single-replica; prefer
  `tooz` for multi-replica HA.)
- **Plumbing is separate:** this chart is the orchestrator. The OVN-IC
  databases + per-AZ `ovn-ic` daemon are the `ovn-ic` chart; the local OVN is
  the `ovn` chart. Deploy those first.
- **Desired state is the source of truth:** the agent only ADDs to Neutron
  routers and only ever creates/deletes its own `ovnic:*` objects.
