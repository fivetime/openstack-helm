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

set -ex

# The vty socket directory is a hostPath shared with the OVN agent and the
# configuration was written by the init container; the FRR daemons run as
# the image's frr user and must own both.
chown frr:frr /var/run/frr
chown -R frr:frr /etc/frr

# The PID files in the hostPath are from the previous FRR of this node, which
# ran in another PID namespace. Left in place, FRR's start-up ("restart all")
# takes their PIDs for running daemons and signals whatever process of this
# container has those numbers, and the daemons may never start.
rm -f /var/run/frr/*.pid

exec /sbin/tini -- /usr/lib/frr/docker-start
