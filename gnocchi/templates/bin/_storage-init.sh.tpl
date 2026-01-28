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

###############################################################################
# 检查是否启用 pool 创建
###############################################################################
POOL_CREATE_ENABLED="${POOL_CREATE_ENABLED:-false}"

if [[ "${POOL_CREATE_ENABLED}" != "true" ]]; then
  echo "=============================================="
  echo "Pool creation disabled (ceph_pool.enabled=false)"
  echo "Skipping pool, user, and secret creation."
  echo "Using external pool and credentials."
  echo "=============================================="
  exit 0
fi

###############################################################################
# 以下仅在 enabled=true 时执行
###############################################################################
SECRET=$(mktemp --suffix .yaml)
KEYRING=$(mktemp --suffix .keyring)
function cleanup {
    rm -f ${SECRET} ${KEYRING}
}
trap cleanup EXIT

ceph -s

###############################################################################
# 创建 CRUSH rule（如果需要指定 deviceClass 或 failureDomain）
###############################################################################
function ensure_crush_rule() {
  local rule_name=$1
  local failure_domain=$2
  local device_class=$3
  local pool_type=$4  # replicated 或 erasure

  # 检查 rule 是否已存在
  if ceph osd crush rule dump ${rule_name} &>/dev/null; then
    echo "CRUSH rule '${rule_name}' already exists"
    return 0
  fi

  echo "Creating CRUSH rule '${rule_name}' with failure_domain=${failure_domain}, device_class=${device_class}"

  if [[ "${pool_type}" == "erasure" ]]; then
    # 纠错池需要特殊处理，使用 erasure-code profile 创建 rule
    # 这里只创建基础 rule，EC pool 会在创建时自动生成 rule
    echo "Erasure pool will use auto-generated rule from EC profile"
    return 0
  fi

  # 复制池的 CRUSH rule
  if [[ -n "${device_class}" && "${device_class}" != "none" ]]; then
    # 使用 device class
    ceph osd crush rule create-replicated ${rule_name} default ${failure_domain} ${device_class}
  else
    # 不指定 device class
    ceph osd crush rule create-replicated ${rule_name} default ${failure_domain}
  fi
}

###############################################################################
# 创建 Erasure Code Profile
###############################################################################
function ensure_ec_profile() {
  local profile_name=$1
  local data_chunks=$2
  local coding_chunks=$3
  local failure_domain=$4
  local device_class=$5

  # 检查 profile 是否已存在
  if ceph osd erasure-code-profile get ${profile_name} &>/dev/null; then
    echo "EC profile '${profile_name}' already exists"
    return 0
  fi

  echo "Creating EC profile '${profile_name}': k=${data_chunks}, m=${coding_chunks}, failure_domain=${failure_domain}"

  local ec_args="k=${data_chunks} m=${coding_chunks} crush-failure-domain=${failure_domain}"

  if [[ -n "${device_class}" && "${device_class}" != "none" ]]; then
    ec_args="${ec_args} crush-device-class=${device_class}"
  fi

  ceph osd erasure-code-profile set ${profile_name} ${ec_args}
}

###############################################################################
# 创建复制池
###############################################################################
function create_replicated_pool() {
  local pool_name=$1
  local pg_num=$2
  local replica_size=$3
  local failure_domain=$4
  local device_class=$5
  local app_name=$6

  # 检查池是否已存在
  if ceph osd pool stats ${pool_name} &>/dev/null; then
    echo "Pool '${pool_name}' already exists"
    ceph osd pool application enable ${pool_name} ${app_name} 2>/dev/null || true
    return 0
  fi

  local rule_name="${pool_name}-rule"

  # 创建 CRUSH rule
  ensure_crush_rule ${rule_name} ${failure_domain} ${device_class} "replicated"

  echo "Creating replicated pool '${pool_name}': size=${replica_size}, pg_num=${pg_num}"

  # 创建池
  if [[ -n "${device_class}" && "${device_class}" != "none" ]]; then
    ceph osd pool create ${pool_name} ${pg_num} ${pg_num} replicated ${rule_name}
  else
    ceph osd pool create ${pool_name} ${pg_num}
  fi

  # 设置副本数
  ceph osd pool set ${pool_name} size ${replica_size}
  ceph osd pool set ${pool_name} min_size $((replica_size / 2 + 1))

  # 启用应用
  ceph osd pool application enable ${pool_name} ${app_name}

  echo "Replicated pool '${pool_name}' created successfully"
}

###############################################################################
# 创建纠错池
###############################################################################
function create_erasure_pool() {
  local pool_name=$1
  local pg_num=$2
  local data_chunks=$3
  local coding_chunks=$4
  local failure_domain=$5
  local device_class=$6
  local app_name=$7

  # 检查池是否已存在
  if ceph osd pool stats ${pool_name} &>/dev/null; then
    echo "Pool '${pool_name}' already exists"
    ceph osd pool application enable ${pool_name} ${app_name} 2>/dev/null || true
    return 0
  fi

  local profile_name="${pool_name}-ec-profile"

  # 创建 EC profile
  ensure_ec_profile ${profile_name} ${data_chunks} ${coding_chunks} ${failure_domain} ${device_class}

  echo "Creating erasure-coded pool '${pool_name}': k=${data_chunks}, m=${coding_chunks}, pg_num=${pg_num}"

  # 创建 EC 池
  ceph osd pool create ${pool_name} ${pg_num} ${pg_num} erasure ${profile_name}

  # 启用应用
  ceph osd pool application enable ${pool_name} ${app_name}

  # 允许 EC overwrites（Gnocchi 需要）
  ceph osd pool set ${pool_name} allow_ec_overwrites true

  echo "Erasure-coded pool '${pool_name}' created successfully"
}

###############################################################################
# 主逻辑：根据配置创建池
###############################################################################
POOL_NAME="${RBD_POOL_NAME}"
POOL_CREATE_ENABLED="${POOL_CREATE_ENABLED:-false}"
POOL_TYPE="${POOL_TYPE:-replicated}"
PG_NUM="${RBD_POOL_CHUNK_SIZE:-32}"
FAILURE_DOMAIN="${FAILURE_DOMAIN:-host}"
DEVICE_CLASS="${DEVICE_CLASS:-}"
APP_NAME="openstack"

# 复制池参数
REPLICA_SIZE="${REPLICA_SIZE:-3}"

# 纠错池参数
EC_DATA_CHUNKS="${EC_DATA_CHUNKS:-4}"
EC_CODING_CHUNKS="${EC_CODING_CHUNKS:-2}"

echo "=============================================="
echo "Storage Init Configuration:"
echo "  Pool Name: ${POOL_NAME}"
echo "  Pool Creation: ${POOL_CREATE_ENABLED}"
echo "=============================================="

if [[ "${POOL_CREATE_ENABLED}" == "true" ]]; then
  echo ""
  echo "Pool Settings:"
  echo "  Type: ${POOL_TYPE}"
  echo "  PG Num: ${PG_NUM}"
  echo "  Failure Domain: ${FAILURE_DOMAIN}"
  echo "  Device Class: ${DEVICE_CLASS:-any}"
  if [[ "${POOL_TYPE}" == "replicated" ]]; then
    echo "  Replica Size: ${REPLICA_SIZE}"
  else
    echo "  EC Data Chunks: ${EC_DATA_CHUNKS}"
    echo "  EC Coding Chunks: ${EC_CODING_CHUNKS}"
  fi
  echo ""

  if [[ "${POOL_TYPE}" == "erasure" || "${POOL_TYPE}" == "ec" ]]; then
    create_erasure_pool ${POOL_NAME} ${PG_NUM} ${EC_DATA_CHUNKS} ${EC_CODING_CHUNKS} ${FAILURE_DOMAIN} "${DEVICE_CLASS}" ${APP_NAME}
  else
    create_replicated_pool ${POOL_NAME} ${PG_NUM} ${REPLICA_SIZE} ${FAILURE_DOMAIN} "${DEVICE_CLASS}" ${APP_NAME}
  fi
else
  echo "Pool creation disabled (ceph_pool.enabled=false)"
  echo "Skipping pool, user, and secret creation..."
  echo "Using external pool and credentials."
  echo "Storage initialization completed (no-op)."
  exit 0
fi

###############################################################################
# 创建 Ceph 用户和 Keyring
###############################################################################
if USERINFO=$(ceph auth get client.${RBD_POOL_USER}); then
  echo "Cephx user client.${RBD_POOL_USER} already exist."
  echo "Update its cephx caps"
  ceph auth caps client.${RBD_POOL_USER} \
    mon "profile rbd, allow r" \
    osd "profile rbd pool=${RBD_POOL_NAME}" \
    mgr "allow r"
  ceph auth get client.${RBD_POOL_USER} -o ${KEYRING}
else
  ceph auth get-or-create client.${RBD_POOL_USER} \
    mon "profile rbd, allow r" \
    osd "profile rbd pool=${RBD_POOL_NAME}" \
    mgr "allow r" \
    -o ${KEYRING}
fi

ENCODED_KEYRING=$(sed -n 's/^[[:blank:]]*key[[:blank:]]\+=[[:blank:]]\(.*\)/\1/p' ${KEYRING} | base64 -w0)
cat > ${SECRET} <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: "${RBD_POOL_SECRET}"
type: kubernetes.io/rbd
data:
  key: $( echo ${ENCODED_KEYRING} )
EOF
kubectl apply --namespace ${NAMESPACE} -f ${SECRET}

echo "Storage initialization completed successfully!"
