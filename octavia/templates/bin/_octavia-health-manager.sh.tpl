#!/bin/sh

{{/*
Copyright 2019 Samsung Electronics Co., Ltd.

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
COMMAND="${@:-start}"

start() {
  # The init containers of the hostNetwork shape leave the port's address
  # in pod-shared and this configures o-hm0 from it. In the attached
  # shape (network.lb_mgmt) there are no init containers: the management
  # interface arrives from the CNI already configured, and there is
  # nothing here to do.
  if [ -f /tmp/pod-shared/HM_PORT_IP ]; then
    HM_PORT_IP=$(cat /tmp/pod-shared/HM_PORT_IP)
    HM_SUBNET_MASK=$(cat /tmp/pod-shared/HM_SUBNET_MASK)
    ip addr flush dev o-hm0
    ip addr add ${HM_PORT_IP}/${HM_SUBNET_MASK} dev o-hm0
    ip link set dev o-hm0 up
{{- if .Values.network.health_manager.interface_mtu }}
    ip link set dev o-hm0 mtu {{ .Values.network.health_manager.interface_mtu }}
{{- end }}
  fi

  # 启动 Octavia 健康管理器
  exec octavia-health-manager \
        --config-file /etc/octavia/octavia.conf \
        --config-dir /etc/octavia/octavia.conf.d
}

stop() {
  # 停止 Octavia 健康管理器
  kill -TERM 1
}

$COMMAND