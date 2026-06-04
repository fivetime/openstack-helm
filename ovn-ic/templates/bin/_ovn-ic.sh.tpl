#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

# Run this AZ's ovn-ic daemon: it syncs the local OVN NB/SB with the global
# Interconnection databases (mirrors transit datapaths into the local NB,
# advertises/learns routes, registers this AZ). Foreground (PID 1) for k8s.

set -ex

RUNDIR="/var/run/ovn"
mkdir -p "${RUNDIR}" /var/log/ovn

# The local OVN NB/SB are a RAFT cluster: connect with the FULL per-pod member
# list (from endpoints.ovn_ovsdb_nb/sb.statefulset.{name,replicas}) so ovn-ic
# follows the RAFT leader and keeps its lock-holding session pinned -- a single
# ClusterIP/LB VIP hides the members and makes the session flap. Addresses are
# stable StatefulSet per-pod DNS names (survive pod reschedule; re-resolved on
# reconnect). The IC dbs (the hub) stay single (single-replica) from env.
exec ovn-ic \
  --ovnnb-db="tcp:{{ tuple "ovn_ovsdb_nb" "internal" "ovsdb" . | include "helm-toolkit.endpoints.host_and_port_endpoint_uri_lookup" | replace "," ",tcp:" }}" \
  --ovnsb-db="tcp:{{ tuple "ovn_ovsdb_sb" "internal" "ovsdb" . | include "helm-toolkit.endpoints.host_and_port_endpoint_uri_lookup" | replace "," ",tcp:" }}" \
  --ic-nb-db="tcp:${OVN_IC_NB_HOST}:${OVN_IC_NB_PORT}" \
  --ic-sb-db="tcp:${OVN_IC_SB_HOST}:${OVN_IC_SB_PORT}" \
  --unixctl="${RUNDIR}/ovn-ic.ctl" \
  --log-file="/var/log/ovn/ovn-ic.log"
