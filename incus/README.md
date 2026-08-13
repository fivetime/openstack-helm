# Incus Helm chart

This chart runs the node-local `incusd` control plane as a privileged
Kubernetes DaemonSet. It does not run LXCFS. The host-owned
`incus-lxcfs.service` Podman Quadlet remains a separate data-plane service so
an `incusd` rollout cannot replace the FUSE process used by running system
containers.

Both roles use the Incus fork's `novm` image. Production values must pin the
Kubernetes image and the LXCFS Quadlet to independently tested image digests.

## Node prerequisites

Node provisioning must create these paths before Helm installs the chart:

```sh
install -d -m 0700 /var/lib/incus /run/incus /var/log/incus
install -d -m 0711 /var/lib/lxcfs
```

The node must also provide:

- systemd with a unified cgroup v2 hierarchy;
- AppArmor and securityfs;
- the host `/dev`, `/run/udev`, and `/lib/modules` trees;
- `/etc/ceph` when the Ceph mount is enabled;
- `incus-lxcfs.service` with a responsive propagated FUSE mount at
  `/var/lib/lxcfs`;
- no Incus-managed networks, because Neutron/OVN/OVS owns tenant networking;
- the `openstack-incus-compute=enabled` label and configured taint
  tolerance.

`/var/lib/incus` and `/run/incus` are host paths, not PVCs. The former contains
the node database and persistent instance state. The latter contains monitor
state and generated `lxc.conf` files required to reconnect after `incusd` is
replaced. Both mounts use bidirectional propagation so instance disk mounts
and runtime material remain visible on the host.

## Runtime model

The Pod uses host networking and host PID visibility, an unconfined AppArmor
and seccomp profile, and privileged device access. Its entrypoint enters the
host cgroup and UTS namespaces, preserving the node hostname, and starts
`incusd` in `/osh-incus` by default. LXC monitor processes inherit that stable
host cgroup instead of the disposable `kubepods` cgroup. Replacing the Pod
therefore removes only the control-plane process; running system containers
and their monitors remain alive.

Readiness requires all of the following:

- the Incus Unix socket and API respond;
- the host LXCFS mount responds;
- the shared Incus runtime directory is present.

Readiness deliberately does not enumerate instances or networks. The Nova
compute init container performs the fail-closed ownership and runtime audit
once before admitting the compute service, and Nova periodic reconciliation
owns per-instance health. A stale instance must not make Kubernetes restart or
withdraw an otherwise healthy node-local Incus control plane.

## Upgrade boundary

Roll `incusd` with the DaemonSet's `RollingUpdate` strategy and
`maxUnavailable: 1`. Record guest init PIDs and workload counters before a
production rollout, then verify they did not reset after each Pod replacement.
The new `incusd` process reopens the host database and reconnects to surviving
LXC monitors.

Do not restart `incus-lxcfs.service` during this operation. An LXCFS restart
invalidates FUSE superblocks already mounted in running guests and requires a
node drain or guest restart. Likewise, an LXC, kernel, device, or host library
update can require draining even when an Incus API-only update does not.

Kubernetes deletion with a normal grace period sends the image's `SIGTERM`
stop signal to `incusd`; do not add a pre-stop hook that signals PID 1 because
the Pod uses host PID visibility and PID 1 is the host init process.

## Initial transition

The first transition from the former Podman-owned `incusd` service is a
maintenance operation:

1. Disable scheduling and drain or cleanly stop all Nova instances on the
   node.
2. Stop and remove the old `incus-podman.service` Quadlet.
3. Keep or install only `incus-lxcfs.service` and validate its host FUSE mount.
4. Ensure `/var/lib/incus`, `/run/incus`, and `/var/log/incus` contain the
   existing state and have the required mount propagation.
5. Install this chart with a digest-pinned `novm` image.
6. Validate the Incus API, LXCFS view, Ceph storage, OVN VIFs, Cinder volumes,
   and Manila mounts before re-enabling scheduling.

After this one-time transition, routine `incusd` image rollouts are owned by
Kubernetes. Host Podman owns only LXCFS.
