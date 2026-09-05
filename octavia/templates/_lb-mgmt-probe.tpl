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

The test is a TCP connect to the other attached agents on the management
network, ready if any one of them answers. Reading it: one pod not ready
points at that pod, and replacing it is the fix. Every pod not ready points
at the management network itself, and the pods are the messenger.

The port is the heartbeat receiver's. A bare connect that never completes the
TLS handshake is what it is meant to be -- the receiver hands the handshake
to a worker thread and logs a failure at debug, so probing costs the peer
nothing and cannot wedge its accept loop.

Call as: list $envAll $ownAddress -- the pod leaves itself out, because a
pod always reaches its own address whether or not the bridge port exists.
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
{{- if $targets }}
readinessProbe:
  exec:
    command:
      - python3
      - -c
      - |
        import socket, sys
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
{{- end }}
{{- end -}}
{{- end -}}
