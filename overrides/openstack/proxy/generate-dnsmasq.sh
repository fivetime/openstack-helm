#!/bin/bash
#
# OpenStack DNS配置生成脚本
# 用途：生成dnsmasq配置，用于解析OpenStack服务域名
# 作者：Simon Zhou
# 日期：2025-05-21
#

# 导入公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-module.sh"

# DNS配置文件路径
DNSMASQ_CONFIG="${OUTPUT_DIR}/dnsmasq-openstack.conf"
DNSMASQ_INSTALL_PATH="/etc/dnsmasq.d/openstack.conf"

# 生成dnsmasq配置
generate_dnsmasq_config() {
    echo "正在生成dnsmasq配置..."

    # 确保域名列表已存在
    if [ ! -f "${OUTPUT_DIR}/domains.txt" ]; then
        get_domain_list
    fi

    # 开始配置文件
    cat > "${DNSMASQ_CONFIG}" << EOF
# OpenStack DNS配置
# 自动生成于 $(date)
# 代理服务器IPv4: ${PROXY_IPV4}
# 代理服务器IPv6: ${PROXY_IPV6}

# 通用域名 - IPv4解析
address=/openstack.svc.cluster.local/${PROXY_IPV4}
address=/openstack.svc/${PROXY_IPV4}
address=/openstack/${PROXY_IPV4}

# 通用域名 - IPv6解析
address=/openstack.svc.cluster.local/${PROXY_IPV6}
address=/openstack.svc/${PROXY_IPV6}
address=/openstack/${PROXY_IPV6}

# 各服务域名解析 (双栈)
EOF

    # 添加所有域名解析，同时支持IPv4和IPv6
    cat "${OUTPUT_DIR}/domains.txt" | while read domain; do
        # 跳过空行
        [ -z "$domain" ] && continue
        echo "address=/${domain}/${PROXY_IPV4}" >> "${DNSMASQ_CONFIG}"
        echo "address=/${domain}/${PROXY_IPV6}" >> "${DNSMASQ_CONFIG}"
    done

    # 添加尾部配置
    cat >> "${DNSMASQ_CONFIG}" << EOF

# 确保正常DNS解析
server=8.8.8.8
server=2001:4860:4860::8888

# 监听所有接口以便远程客户端访问
interface=*

# 记录查询日志，便于调试
log-queries
log-facility=/var/log/dnsmasq.log

# IPv6配置
enable-ra
dhcp-range=::1,::400,constructor:eth0,ra-stateless,64,infinite
EOF

    echo "dnsmasq配置已生成到 ${DNSMASQ_CONFIG}"
}

# 部署dnsmasq配置
deploy_dnsmasq_config() {
    # 备份现有配置
    backup_config "dnsmasq" "${DNSMASQ_INSTALL_PATH}"

    echo "正在安装dnsmasq..."
    apt update && apt install -y dnsmasq || {
        echo "错误: 无法安装dnsmasq，请手动安装"
        return 1
    }

    echo "部署dnsmasq配置..."
    cp "${DNSMASQ_CONFIG}" "${DNSMASQ_INSTALL_PATH}"

    echo "重启dnsmasq服务..."
    systemctl restart dnsmasq
    systemctl enable dnsmasq

    echo "dnsmasq配置已部署"
    return 0
}

# 主函数
main() {
    echo "===== OpenStack DNS配置生成工具 ====="
    echo "代理服务器IPv4: ${PROXY_IPV4}"
    echo "代理服务器IPv6: ${PROXY_IPV6}"
    echo "输出目录: ${OUTPUT_DIR}"
    echo "====================================="

    # 检查依赖
    check_dependencies || exit 1

    # 收集数据，如果文件不存在
    if [ ! -f "${OUTPUT_DIR}/services.json" ] || [ ! -f "${OUTPUT_DIR}/domains.txt" ]; then
        collect_openstack_data
    fi

    # 生成配置
    generate_dnsmasq_config

    # 询问是否部署
    echo "是否要部署dnsmasq配置? (y/n)"
    read deploy_answer

    if [ "${deploy_answer}" = "y" ] || [ "${deploy_answer}" = "Y" ]; then
        deploy_dnsmasq_config

        # 显示验证命令
        echo "验证DNS配置:"
        echo "  dig @${PROXY_IPV4} keystone.openstack.svc.cluster.local"
        echo "  dig @${PROXY_IPV6} AAAA keystone.openstack.svc.cluster.local"
    else
        echo "配置未部署，仅生成文件。"
    fi

    echo "DNS配置脚本执行完成。"
}

# 运行主函数
main