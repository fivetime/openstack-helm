#!/bin/sh

set -ex
COMMAND="${@:-start}"

start() {
  # Static, not dhclient: the management network is IPv6-only and
  # `dhclient -v o-w0` is a DHCPv4 client that never gets a lease. With set -e
  # that is a crash loop whose events say only "BackOff".
  # POSIX sh, not bash: the fork's alpine image has no bash.
  HM_PORT_IP=$(cat /tmp/pod-shared/HM_PORT_IP)
  HM_SUBNET_MASK=$(cat /tmp/pod-shared/HM_SUBNET_MASK)

  ip addr flush dev o-w0
  ip addr add ${HM_PORT_IP}/${HM_SUBNET_MASK} dev o-w0
  ip link set dev o-w0 up
  ip link set dev o-w0 mtu {{ .Values.network.health_manager.interface_mtu }}

  exec octavia-worker \
        --config-file /etc/octavia/octavia.conf \
        --config-dir /etc/octavia/octavia.conf.d
}

stop() {
  kill -TERM 1
}

$COMMAND
