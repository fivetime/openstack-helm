#!/bin/bash

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

function start () {
  # 从共享目录读取网络配置信息
  HM_PORT_IP=$(cat /tmp/pod-shared/HM_PORT_IP)
  HM_SUBNET_MASK=$(cat /tmp/pod-shared/HM_SUBNET_MASK)

  # 静态配置网络接口
  ip addr flush dev o-hm0
  ip addr add ${HM_PORT_IP}/${HM_SUBNET_MASK} dev o-hm0
  ip link set dev o-hm0 up

  # 启动 Octavia 健康管理器
  exec octavia-health-manager \
        --config-file /etc/octavia/octavia.conf
}

function stop () {
  # 停止 Octavia 健康管理器
  kill -TERM 1
}

$COMMAND