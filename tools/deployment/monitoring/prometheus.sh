#!/bin/bash

#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

set -xe

: ${OSH_HELM_REPO:="../openstack-helm"}
: ${OSH_VALUES_OVERRIDES_PATH:="../openstack-helm/values_overrides"}
FEATURES="alertmanager ceph elasticsearch kubernetes nodes openstack postgresql apparmor ${FEATURES}"
: ${OSH_EXTRA_HELM_ARGS_PROMETHEUS:="$(helm osh get-values-overrides -p ${OSH_VALUES_OVERRIDES_PATH} -c prometheus ${FEATURES})"}


#NOTE: Deploy command
helm upgrade --install prometheus ${OSH_HELM_REPO}/prometheus \
    --namespace=osh-infra \
    ${VOLUME_HELM_ARGS:="--set storage.enabled=false --set storage.use_local_path.enabled=true"} \
    ${OSH_EXTRA_HELM_ARGS:=} \
    ${OSH_EXTRA_HELM_ARGS_PROMETHEUS}

#NOTE: Wait for deploy
helm osh wait-for-pods osh-infra

# Delete the test pod if it still exists
kubectl delete pods -l application=prometheus,release_group=prometheus,component=test --namespace=osh-infra --ignore-not-found
helm test prometheus --namespace osh-infra
