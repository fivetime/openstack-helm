{{/*
Readiness for a pod whose management network comes from Multus + ovs-cni.

The ovs-cni port is made when the pod is made. If the node's openvswitch
restarts, br-int comes back without it: the pod keeps running, its interface
is still there with its address still on it, and nothing about the pod looks
wrong -- but the Neutron port reads up=false with no chassis binding and not
a packet moves. On the production cluster that happened to a driver agent
holding the provider lock, and for three hours it failed every convergence
while the healthy replica watched and a load balancer sat in ERROR.

What this probe does is make it visible. What it cannot do is repair it: CNI
runs when the pod's sandbox is created, so restarting the container keeps the
same dead interface, and only replacing the pod gets a new port. A liveness
probe here would crash-loop forever instead of recovering, which is why this
is readiness.

Two tests, and a pod is ready if either passes.

The first is local and is what tells one broken pod apart from a broken
network: has this interface received anything since the last look. Workers
push heartbeats to every driver agent every couple of seconds, so on a live
interface the counter always moves, and on an orphaned port it stops dead.
Nothing about it depends on any other pod being well.

The second is a TCP connect to the other attached agents, for the pods that
legitimately receive nothing -- a health manager with no amphorae has a
silent interface all day. The port is the heartbeat receiver's, which hands
the handshake to a worker thread and logs a failure at debug, so a connect
that goes no further costs the peer nothing and cannot wedge its accept
loop. A pod leaves its own address out, because it reaches that whether or
not the bridge port exists.

The local test came second and had to. With it, the peer test alone marked
both driver agents not ready when one of them lost its port -- each has only
the other to aim at -- which pointed at the network rather than at the pod
that was actually broken. Measured in a fault injection on production, and
the reason the counter is read at all.

Reading it: one pod not ready points at that pod, and replacing it is the
fix. Every pod not ready points at the management network itself.

Call as: list $envAll $ownAddress
*/}}
{{- define "octavia.lb_mgmt.readiness" -}}
{{- $envAll := index . 0 -}}
{{- $own := index . 1 -}}
{{- $lbMgmt := $envAll.Values.network.lb_mgmt -}}
{{- $probe := $lbMgmt.probe | default dict -}}
{{- if $probe.enabled -}}
{{- $targets := list -}}
{{- range $slot := ($lbMgmt.attachments.driver_agent | default list) -}}
{{- if ne $slot.ip $own -}}
{{- $targets = append $targets $slot.ip -}}
{{- end -}}
{{- end -}}
readinessProbe:
  exec:
    command:
      - python3
      - -c
      - |
        import json, socket, sys, time
        seen = '/tmp/.lb-mgmt-probe'
        counter = '/sys/class/net/{{ $probe.interface }}/statistics/rx_packets'
        try:
            received = int(open(counter).read())
        except (OSError, ValueError):
            received = None
        if received is not None:
            try:
                before = json.load(open(seen))['received']
            except Exception:
                # Nothing to compare against yet: say so by passing, and
                # leave the peer test to speak for the first interval.
                before = -1
            try:
                json.dump({'received': received, 'at': time.time()},
                          open(seen, 'w'))
            except OSError:
                pass
            if received > before:
                sys.exit(0)
        for target in sys.argv[1:]:
            try:
                socket.create_connection(
                    (target, {{ $probe.port }}), timeout={{ $probe.timeout }}).close()
                sys.exit(0)
            except OSError:
                pass
        sys.exit(1)
{{- range $target := $targets }}
      - {{ $target | quote }}
{{- end }}
  initialDelaySeconds: {{ $probe.initial_delay }}
  periodSeconds: {{ $probe.period }}
  timeoutSeconds: {{ add $probe.timeout 5 }}
  failureThreshold: {{ $probe.failure_threshold }}
{{- end -}}
{{- end -}}
