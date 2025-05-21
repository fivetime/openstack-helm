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

if [ "x" == "x${PROVISIONER_INTERFACE}" ]; then
  echo "Provisioner interface is not set"
  exit 1
fi

function net_pxe_addr {
  # 首先检查接口是否存在
  if ! ip link show ${PROVISIONER_INTERFACE} &>/dev/null; then
    echo "Interface ${PROVISIONER_INTERFACE} does not exist"
    return 1
  fi

  # 尝试查找接口上的所有 IPv4 地址
  local all_ips=($(ip -4 -o addr show dev ${PROVISIONER_INTERFACE} | awk '{print $4}'))

  if [ ${#all_ips[@]} -eq 0 ]; then
    echo "No IPv4 addresses found on ${PROVISIONER_INTERFACE}"
    return 1
  fi

  # 尝试找到预期网段的 IP（基于配置的 neutron_subnet_cidr）
  # 优先匹配 10.0.144.0/20 网段
  for ip in "${all_ips[@]}"; do
    if [[ "$ip" =~ ^10\.0\.144\. || "$ip" =~ ^10\.0\.1[45][0-9]\. ]]; then
      echo "$ip"
      return 0
    fi
  done

  # 如果没有找到预期网段的 IP，使用其他网段的第一个 IP
  # 尝试 10.0.64.0/20 网段（如您提供的示例）
  for ip in "${all_ips[@]}"; do
    if [[ "$ip" =~ ^10\.0\.6[4-9]\. || "$ip" =~ ^10\.0\.7[0-9]\. ]]; then
      echo "$ip"
      return 0
    fi
  done

  # 如果仍然没有找到匹配的网段，使用第一个可用的 IP
  echo "${all_ips[0]}"
}

function net_pxe_ip {
  local addr=$(net_pxe_addr)
  if [ -n "$addr" ]; then
    echo "$addr" | awk -F '/' '{ print $1; exit }'
  fi
}

PXE_IP=$(net_pxe_ip)

if [ "x" == "x${PXE_IP}" ]; then
  echo "Could not find IP for pxe to bind to on interface ${PROVISIONER_INTERFACE}"
  echo "Available addresses on ${PROVISIONER_INTERFACE}:"
  ip -4 -o addr show dev ${PROVISIONER_INTERFACE} || echo "  None or interface doesn't exist"
  exit 1
fi

echo "Using PXE IP: ${PXE_IP} on interface ${PROVISIONER_INTERFACE}"

# ensure the tempdir exists, read it from the config
ironictmpdir=$(python -c 'from configparser import ConfigParser;cfg = ConfigParser();cfg.read("/etc/ironic/ironic.conf");print(cfg.get("DEFAULT", "tempdir", fallback=""))')
if [ -n "${ironictmpdir}" -a ! -d "${ironictmpdir}" ]; then
  mkdir -p "${ironictmpdir}"
  chmod 1777 "${ironictmpdir}"
fi

tee /tmp/pod-shared/conductor-local-ip.conf << EOF
[DEFAULT]

# IP address of this host. If unset, will determine the IP
# programmatically. If unable to do so, will use "127.0.0.1".
# (string value)
my_ip = ${PXE_IP}

[pxe]
# IP address of ironic-conductor node's TFTP server. (string
# value)
tftp_server = ${PXE_IP}

[deploy]
# ironic-conductor node's HTTP server URL. Example:
# http://192.1.2.3:8080 (string value)
# from .deploy.ironic.http_url
http_url = http://${PXE_IP}:{{ tuple "baremetal" "internal" "pxe_http" . | include "helm-toolkit.endpoints.endpoint_port_lookup" }}
EOF