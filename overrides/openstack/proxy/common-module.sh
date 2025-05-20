#!/bin/bash
#
# OpenStack代理配置工具 - 公共函数库
# 用途：提供共享函数和配置变量
# 作者：Simon Zhou
# 日期：2025-05-21
#

# 配置变量
PROXY_IPV4="10.0.16.10"  # 代理服务器IPv4地址
PROXY_IPV6="fd00:1:1:0:10:0:16:10"  # 代理服务器IPv6地址
PUBLIC_OPENSTACK_IP="10.0.30.110"  # OpenStack服务IP (仅IPv4)
OPENSTACK_NAMESPACE="openstack"  # OpenStack命名空间
OUTPUT_DIR="/tmp/openstack-proxy"  # 输出目录
BACKUP_DIR="${OUTPUT_DIR}/backups/$(date +%Y%m%d%H%M%S)"  # 备份目录

# 创建输出目录
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${BACKUP_DIR}"

# 检查依赖
check_dependencies() {
    echo "检查依赖项..."

    # 检查kubectl
    if ! command -v kubectl &> /dev/null; then
        echo "错误: kubectl命令未找到，请安装并确保可以连接到Kubernetes集群"
        return 1
    fi

    # 检查jq
    if ! command -v jq &> /dev/null; then
        echo "正在安装jq..."
        apt update && apt install -y jq || {
            echo "错误: 无法安装jq，请手动安装"
            return 1
        }
    fi

    # 检查是否可以访问OpenStack命名空间
    if ! kubectl get namespace ${OPENSTACK_NAMESPACE} &> /dev/null; then
        echo "错误: 无法访问${OPENSTACK_NAMESPACE}命名空间，请检查kubectl配置"
        return 1
    fi

    echo "依赖检查完成"
    return 0
}

# 获取OpenStack服务数据
get_service_data() {
    echo "正在获取OpenStack服务数据..."
    kubectl -n ${OPENSTACK_NAMESPACE} get svc -o json > "${OUTPUT_DIR}/services.json"
}

# 获取OpenStack端点数据
get_endpoint_data() {
    echo "正在获取OpenStack端点数据..."
    kubectl -n ${OPENSTACK_NAMESPACE} get endpoints -o json > "${OUTPUT_DIR}/endpoints.json" 2>/dev/null || true
}

# 获取OpenStack Ingress数据
get_ingress_data() {
    echo "正在获取OpenStack Ingress数据..."
    kubectl -n ${OPENSTACK_NAMESPACE} get ingress -o json > "${OUTPUT_DIR}/ingress.json" 2>/dev/null || true
}

# 获取所有服务端口
get_all_service_ports() {
    echo "正在提取服务端口信息..."
    jq -r '.items[].spec.ports[] | .port' "${OUTPUT_DIR}/services.json" | sort -n | uniq > "${OUTPUT_DIR}/ports.txt"
    echo "总共发现 $(wc -l < ${OUTPUT_DIR}/ports.txt) 个唯一端口"
}

# 生成服务域名列表
get_domain_list() {
    echo "正在生成服务域名列表..."

    # 从服务数据中提取名称
    local services=$(jq -r '.items[].metadata.name' "${OUTPUT_DIR}/services.json" | sort | uniq)
    local domain_list="${OUTPUT_DIR}/domains.txt"

    # 创建域名列表
    > "${domain_list}"

    # 为每个服务生成所有可能的域名格式
    for service in ${services}; do
        echo "${service}" >> "${domain_list}"
        echo "${service}.openstack" >> "${domain_list}"
        echo "${service}.openstack.svc" >> "${domain_list}"
        echo "${service}.openstack.svc.cluster.local" >> "${domain_list}"
    done

    # 获取从OpenStack端点中的域名（如果文件存在）
    if [ -f "${OUTPUT_DIR}/endpoints.json" ]; then
        jq -r '.subsets[].addresses[].hostname' "${OUTPUT_DIR}/endpoints.json" 2>/dev/null | grep -v "^$" | sort | uniq >> "${domain_list}" || true
    fi

    # 添加从Ingress资源中获取的主机名（如果文件存在）
    if [ -f "${OUTPUT_DIR}/ingress.json" ]; then
        jq -r '.items[].spec.rules[].host' "${OUTPUT_DIR}/ingress.json" 2>/dev/null | grep -v "^$" | sort | uniq >> "${domain_list}" || true
    fi

    # 去重排序
    sort -u "${domain_list}" -o "${domain_list}"

    echo "域名列表已生成至 ${domain_list}"
    echo "共找到 $(wc -l < ${domain_list}) 个唯一域名"
}

# 收集所有OpenStack数据
collect_openstack_data() {
    echo "正在收集OpenStack集群数据..."
    get_service_data
    get_endpoint_data
    get_ingress_data
    get_domain_list
    get_all_service_ports
    echo "数据收集完成"
}

# 备份现有配置
backup_config() {
    local config_type=$1
    local config_path=$2

    if [ -f "${config_path}" ]; then
        echo "备份现有 ${config_type} 配置..."
        cp "${config_path}" "${BACKUP_DIR}/${config_type}-$(date +%Y%m%d%H%M%S).conf"
    fi
}