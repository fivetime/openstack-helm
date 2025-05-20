#!/bin/bash
#
# OpenStack代理完整部署脚本
# 用途：一键部署OpenStack代理服务（DNS+Nginx）
# 作者：Simon Zhou
# 日期：2025-05-21
#

# 导入公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-module.sh"

# 确保IPv6功能可用
enable_ipv6() {
    echo "检查IPv6支持..."
    if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = "1" ]; then
        echo "启用IPv6支持..."
        cat > /etc/sysctl.d/99-ipv6.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
EOF
        sysctl -p /etc/sysctl.d/99-ipv6.conf

        # 检查IPv6是否已启用
        if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = "1" ]; then
            echo "警告: 无法启用IPv6，请手动检查系统配置"
        else
            echo "IPv6已启用"
        fi
    else
        echo "IPv6已经启用"
    fi
}

# 部署所有配置
deploy_all() {
    echo "开始全面部署OpenStack代理配置..."

    # 收集数据
    collect_openstack_data

    # 运行DNS配置脚本
    echo "生成DNS配置..."
    "${SCRIPT_DIR}/generate-dnsmasq.sh"
    # 部署DNS配置
    cp "${OUTPUT_DIR}/dnsmasq-openstack.conf" "/etc/dnsmasq.d/openstack.conf" || {
        echo "错误: 无法部署dnsmasq配置"
        return 1
    }

    # 运行Nginx配置脚本
    echo "生成Nginx配置..."
    "${SCRIPT_DIR}/generate-nginx.sh"

    # 部署Nginx配置
    mkdir -p /etc/nginx/ssl
    if [ ! -f "/etc/nginx/ssl/nginx.crt" ]; then
        echo "生成自签名SSL证书..."
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/nginx/ssl/nginx.key \
            -out /etc/nginx/ssl/nginx.crt \
            -subj "/CN=openstack-proxy"
    fi

    # 复制并启用Nginx配置
    cp "${OUTPUT_DIR}/nginx-openstack-proxy.conf" "/etc/nginx/sites-available/openstack-proxy" || {
        echo "错误: 无法部署nginx配置"
        return 1
    }

    ln -sf "/etc/nginx/sites-available/openstack-proxy" "/etc/nginx/sites-enabled/openstack-proxy"

    # 禁用默认配置（如果存在）
    if [ -L "/etc/nginx/sites-enabled/default" ]; then
        rm -f "/etc/nginx/sites-enabled/default"
    fi

    # 重启服务
    echo "重启服务..."
    systemctl restart dnsmasq
    systemctl restart nginx

    # 设置开机启动
    echo "设置服务开机自启..."
    systemctl enable dnsmasq
    systemctl enable nginx

    echo "配置已完成部署"
    return 0
}

# 检查防火墙并开放必要端口
configure_firewall() {
    echo "配置防火墙..."

    # 检查使用的是哪种防火墙
    if command -v ufw &> /dev/null; then
        echo "发现ufw防火墙，开放必要端口..."

        # DNS端口
        ufw allow 53/tcp
        ufw allow 53/udp

        # Web端口
        ufw allow 80/tcp
        ufw allow 443/tcp

        # 常用OpenStack API端口
        ufw allow 5000/tcp  # Keystone
        ufw allow 8774/tcp  # Nova
        ufw allow 9292/tcp  # Glance
        ufw allow 8778/tcp  # Placement
        ufw allow 8776/tcp  # Cinder
        ufw allow 9696/tcp  # Neutron

        # 如果需要允许更多端口，可以从ports.txt中读取
        if [ -f "${OUTPUT_DIR}/ports.txt" ]; then
            cat "${OUTPUT_DIR}/ports.txt" | while read port; do
                [ -z "$port" ] && continue
                ufw allow ${port}/tcp
            done
        fi

        echo "ufw防火墙配置完成"

    elif command -v firewall-cmd &> /dev/null; then
        echo "发现firewalld防火墙，开放必要端口..."

        # 允许服务
        firewall-cmd --permanent --add-service=dns
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https

        # 允许端口
        firewall-cmd --permanent --add-port=5000/tcp  # Keystone
        firewall-cmd --permanent --add-port=8774/tcp  # Nova
        firewall-cmd --permanent --add-port=9292/tcp  # Glance
        firewall-cmd --permanent --add-port=8778/tcp  # Placement
        firewall-cmd --permanent --add-port=8776/tcp  # Cinder
        firewall-cmd --permanent --add-port=9696/tcp  # Neutron

        # 如果需要允许更多端口，可以从ports.txt中读取
        if [ -f "${OUTPUT_DIR}/ports.txt" ]; then
            cat "${OUTPUT_DIR}/ports.txt" | while read port; do
                [ -z "$port" ] && continue
                firewall-cmd --permanent --add-port=${port}/tcp
            done
        fi

        # 重新加载防火墙
        firewall-cmd --reload

        echo "firewalld防火墙配置完成"
    else
        echo "未检测到已知的防火墙工具，请手动配置防火墙以允许必要的端口"
    fi
}

# 验证部署
verify_deployment() {
    echo "验证部署..."

    # 验证DNS
    echo "验证DNS配置..."
    if command -v dig &> /dev/null; then
        echo "使用dig验证DNS解析..."
        dig @127.0.0.1 keystone.openstack.svc.cluster.local +short
        dig @127.0.0.1 AAAA keystone.openstack.svc.cluster.local +short
    elif command -v nslookup &> /dev/null; then
        echo "使用nslookup验证DNS解析..."
        nslookup keystone.openstack.svc.cluster.local 127.0.0.1
    else
        echo "未找到DNS验证工具(dig/nslookup)，跳过DNS验证"
    fi

    # 验证Nginx
    echo "验证Nginx配置..."
    nginx -t

    # 验证端口监听
    echo "验证端口监听..."
    netstat -tulpn | grep -E ':(80|443|53|5000)'

    echo "验证完成，请确认上述输出是否符合预期"
}

# 主函数
main() {
    echo "===== OpenStack代理完整部署工具 ====="
    echo "代理服务器IPv4: ${PROXY_IPV4}"
    echo "代理服务器IPv6: ${PROXY_IPV6}"
    echo "OpenStack服务IP: ${PUBLIC_OPENSTACK_IP}"
    echo "====================================="

    # 检查脚本是否以root运行
    if [ "$(id -u)" != "0" ]; then
        echo "错误: 此脚本需要root权限运行"
        exit 1
    fi

    # 检查依赖
    check_dependencies || exit 1

    # 确保IPv6功能可用
    enable_ipv6

    # 安装必要软件包
    echo "安装必要软件包..."
    apt update && apt install -y dnsmasq nginx openssl dnsutils net-tools || {
        echo "错误: 无法安装必要软件包"
        exit 1
    }

    # 部署所有配置
    deploy_all || exit 1

    # 配置防火墙
    configure_firewall

    # 验证部署
    verify_deployment

    echo "OpenStack代理已成功部署！"
    echo "代理服务器IPv4: ${PROXY_IPV4}"
    echo "代理服务器IPv6: ${PROXY_IPV6}"
    echo ""
    echo "客户端配置说明:"
    echo "1. 将DNS服务器设置为 ${PROXY_IPV4} 或 ${PROXY_IPV6}"
    echo "2. 使用普通域名访问OpenStack服务，如:"
    echo "   export OS_AUTH_URL=\"http://keystone/v3\""
    echo "   或者"
    echo "   export OS_AUTH_URL=\"http://keystone.openstack.svc.cluster.local/v3\""
    echo ""
    echo "3. 对IPv6客户端，可使用:"
    echo "   export OS_AUTH_URL=\"http://[${PROXY_IPV6}]:5000/v3\""
}

# 运行主函数
main