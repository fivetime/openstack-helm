#!/bin/bash -xe

# Copyright 2023 VEXXHOST, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Source library functions
source /tmp/ovn-lib.sh

ANNOTATION_KEY="openstack-helm/ovn-system-id"

function get_current_system_id {
  ovs-vsctl --if-exists get Open_vSwitch . external_ids:system-id | tr -d '"'
}

function get_stored_system_id {
  kubectl get node "$NODE_NAME" -o "jsonpath={.metadata.annotations.openstack-helm/ovn-system-id}"
}

function store_system_id() {
  local system_id=$1
  kubectl annotate node "$NODE_NAME" "$ANNOTATION_KEY=$system_id"
}

# Detect tunnel interface
tunnel_interface="{{- .Values.network.interface.tunnel -}}"
if [ -z "${tunnel_interface}" ] ; then
    tunnel_network_cidr="{{- .Values.network.interface.tunnel_network_cidr -}}"
    if [ -z "${tunnel_network_cidr}" ] ; then
        tunnel_network_cidr="0/0"
    fi
    tunnel_interface=$(ip -4 route list ${tunnel_network_cidr} | awk -F 'dev' '{ print $2; exit }' \
        | awk '{ print $1 }') || exit 1
fi
ovs-vsctl set open . external_ids:ovn-encap-ip="$(get_ip_address_from_interface ${tunnel_interface})"

# Get the stored system-id from the Kubernetes node annotation
stored_system_id=$(get_stored_system_id)

# Get the current system-id set in OVS
current_system_id=$(get_current_system_id)

if [ -n "$stored_system_id" ] && [ "$stored_system_id" != "$current_system_id" ]; then
  ovs-vsctl set Open_vSwitch . external_ids:system-id="$stored_system_id"
elif [ -z "$current_system_id" ]; then
  current_system_id=$(uuidgen)
  ovs-vsctl set Open_vSwitch . external_ids:system-id="$current_system_id"
  store_system_id "$current_system_id"
elif [ -z "$stored_system_id" ]; then
  store_system_id "$current_system_id"
fi

# Configure OVN remote
{{- if empty .Values.conf.ovn_remote -}}
{{- $sb_svc_name := "ovn-ovsdb-sb" -}}
{{- $sb_svc := (tuple $sb_svc_name "internal" . | include "helm-toolkit.endpoints.hostname_fqdn_endpoint_lookup") -}}
{{- $sb_port := (tuple "ovn-ovsdb-sb" "internal" "ovsdb" . | include "helm-toolkit.endpoints.endpoint_port_lookup") -}}
{{- $sb_service_list := list -}}
{{- range $i := until (.Values.pod.replicas.ovn_ovsdb_sb | int) -}}
  {{- $sb_service_list = printf "tcp:%s-%d.%s:%s" $sb_svc_name $i $sb_svc $sb_port | append $sb_service_list -}}
{{- end }}
ovs-vsctl set open . external-ids:ovn-remote="{{ include "helm-toolkit.utils.joinListWithComma" $sb_service_list }}"
{{- else -}}
ovs-vsctl set open . external-ids:ovn-remote="{{ .Values.conf.ovn_remote }}"
{{- end }}

# Configure OVN values
ovs-vsctl set open . external-ids:rundir="/var/run/openvswitch"
ovs-vsctl set open . external-ids:ovn-encap-type="{{ .Values.conf.ovn_encap_type }}"
ovs-vsctl set open . external-ids:ovn-bridge="{{ .Values.conf.ovn_bridge }}"
ovs-vsctl set open . external-ids:ovn-bridge-mappings="{{ .Values.conf.ovn_bridge_mappings }}"
ovs-vsctl set open . external-ids:ovn-monitor-all="{{ .Values.conf.ovn_monitor_all }}"

GW_ENABLED=$(cat /tmp/gw-enabled/gw-enabled)
if [[ ${GW_ENABLED} == {{ .Values.labels.ovn_controller_gw.node_selector_value }} ]]; then
  ovs-vsctl set open . external-ids:ovn-cms-options={{ .Values.conf.ovn_cms_options_gw_enabled }}
else
  ovs-vsctl set open . external-ids:ovn-cms-options={{ .Values.conf.ovn_cms_options }}
fi

{{ if .Values.conf.ovn_bridge_datapath_type -}}
ovs-vsctl set open . external-ids:ovn-bridge-datapath-type="{{ .Values.conf.ovn_bridge_datapath_type }}"
{{- end }}

# -------------- EVPN Configuration Start --------------
{{- if .Values.conf.evpn.enabled }}
# OVN Native BGP-EVPN Integration
# Reference: https://docs.ovn.org/en/latest/tutorials/ovn-bgp-evpn.html

# Determine VTEP interface and IP
{{- if .Values.conf.evpn.vtep_interface }}
evpn_vtep_interface="{{ .Values.conf.evpn.vtep_interface }}"
{{- else if .Values.conf.evpn.vtep_network_cidr }}
evpn_vtep_network_cidr="{{ .Values.conf.evpn.vtep_network_cidr }}"
evpn_vtep_interface=$(ip -4 route list ${evpn_vtep_network_cidr} | awk -F 'dev' '{ print $2; exit }' | awk '{ print $1 }')
if [ -z "${evpn_vtep_interface}" ]; then
  echo "Warning: Could not find interface for EVPN VTEP network CIDR ${evpn_vtep_network_cidr}, falling back to tunnel interface"
  evpn_vtep_interface="${tunnel_interface}"
fi
{{- else }}
evpn_vtep_interface="${tunnel_interface}"
{{- end }}
evpn_vtep_ip=$(get_ip_address_from_interface ${evpn_vtep_interface})

echo "Configuring OVN native EVPN support..."
echo "  VTEP Interface: ${evpn_vtep_interface}"
echo "  VTEP IP: ${evpn_vtep_ip}"
echo "  VXLAN Port: {{ .Values.conf.evpn.vxlan_port }}"

ovs-vsctl set Open_vSwitch . external-ids:ovn-evpn-local-ip="${evpn_vtep_ip}"
ovs-vsctl set Open_vSwitch . external-ids:ovn-evpn-vxlan-ports="{{ .Values.conf.evpn.vxlan_port }}"

echo "OVN native EVPN configuration completed."
{{- end }}
# -------------- EVPN Configuration End --------------

# Configure hostname
{{- if .Values.pod.use_fqdn.compute }}
  ovs-vsctl set open . external-ids:hostname="$(hostname -f)"
{{- else }}
  ovs-vsctl set open . external-ids:hostname="$(hostname)"
{{- end }}

# Create bridges and create ports
# handle any bridge mappings
# /tmp/auto_bridge_add is one line json file: {"br-ex1":"eth1","br-ex2":"eth2"}
for bmap in `sed 's/[{}"]//g' /tmp/auto_bridge_add | tr "," "\n"`
do
  bridge=${bmap%:*}
  iface=${bmap#*:}
  # -------------- Modify by Simon Start --------------
  ovs-vsctl --may-exist add-br $bridge      # Auto Negotiate
  #ovs-vsctl --may-exist add-br $bridge -- set bridge $bridge protocols=OpenFlow13
  # -------------- Modify by Simon End --------------
  if [ -n "$iface" ] && [ "$iface" != "null" ] && ( ip link show $iface 1>/dev/null 2>&1 );
  then
    ovs-vsctl --may-exist add-port $bridge $iface
    migrate_ip_from_nic $iface $bridge
  fi
done