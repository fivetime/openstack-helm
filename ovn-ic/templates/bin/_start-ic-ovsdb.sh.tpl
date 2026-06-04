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

# Bootstrap + run one of the global OVN Interconnection databases (IC-NB or
# IC-SB) as a standalone ovsdb-server. ovn-ic / ovn-ic-nbctl on every AZ talk
# to it. OVN_IC_DB is "nb" or "sb"; OVN_IC_PORT is the TCP port to listen on.

set -ex

: "${OVN_IC_DB:?must be nb or sb}"
: "${OVN_IC_PORT:?ic db tcp port}"

SCHEMA="/usr/share/ovn/ovn-ic-${OVN_IC_DB}.ovsschema"
DBDIR="${OVN_IC_DBDIR:-/var/lib/ovn}"
RUNDIR="/var/run/ovn"
DBFILE="${DBDIR}/ovn_ic_${OVN_IC_DB}.db"

mkdir -p "${DBDIR}" "${RUNDIR}" /var/log/ovn

# Create the db on first start; convert in place on a schema upgrade.
if [ ! -f "${DBFILE}" ]; then
  ovsdb-tool create "${DBFILE}" "${SCHEMA}"
elif [ "$(ovsdb-tool needs-conversion "${DBFILE}" "${SCHEMA}")" = "yes" ]; then
  ovsdb-tool convert "${DBFILE}" "${SCHEMA}"
fi

exec ovsdb-server "${DBFILE}" \
  --remote="punix:${RUNDIR}/ovn_ic_${OVN_IC_DB}_db.sock" \
  --remote="ptcp:${OVN_IC_PORT}:0.0.0.0" \
  --unixctl="${RUNDIR}/ovn_ic_${OVN_IC_DB}_db.ctl" \
  --pidfile="${RUNDIR}/ovn_ic_${OVN_IC_DB}_db.pid" \
  --log-file="/var/log/ovn/ovsdb-server-ic-${OVN_IC_DB}.log"
