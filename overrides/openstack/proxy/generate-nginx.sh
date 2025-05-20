#!/bin/bash
#
# OpenStack Nginx代理配置生成脚本
# 用途：生成nginx配置，用于代理OpenStack服务请求
# 作者：Simon Zhou
# 日期：2025-05-21
#

# 导入公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-module.sh"

# Nginx配置文件路径
NGINX_CONFIG="${OUTPUT_DIR}/nginx-openstack-proxy.conf"
NGINX_INSTALL_PATH="/etc/nginx/sites-available/openstack-proxy"
NGINX_ENABLED_PATH="/etc/nginx/sites-enabled/openstack-proxy"

# 生成Nginx配置
generate_nginx_config() {
    echo "正在生成nginx配置..."

    # 确保域名和端口列表已存在
    if [ ! -f "${OUTPUT_DIR}/domains.txt" ]; then
        get_domain_list
    fi

    if [ ! -f "${OUTPUT_DIR}/ports.txt" ]; then
        get_all_service_ports
    fi

    # 开始配置文件
    cat > "${NGINX_CONFIG}" << EOF
# OpenStack Nginx代理配置
# 自动生成于 $(date)
# 代理服务器IPv4: ${PROXY_IPV4}
# 代理服务器IPv6: ${PROXY_IPV6}
# OpenStack公共服务IP: ${PUBLIC_OPENSTACK_IP}

# HTTP代理配置
server {
    listen 80;
    listen [::]:80 ipv6only=on;

    # 匹配所有OpenStack相关域名
    server_name
EOF

    # 添加域名匹配规则
    echo "        # 正则匹配" >> "${NGINX_CONFIG}"
    echo "        ~^.*\.openstack\.svc\.cluster\.local$" >> "${NGINX_CONFIG}"
    echo "        ~^.*\.openstack\.svc$" >> "${NGINX_CONFIG}"
    echo "        ~^.*\.openstack$" >> "${NGINX_CONFIG}"

    # 添加各服务名称
    echo "        # 服务名称" >> "${NGINX_CONFIG}"
    cat "${OUTPUT_DIR}/domains.txt" | while read domain; do
        # 跳过空行和已经通过正则匹配的域
        [ -z "$domain" ] && continue
        if [[ "${domain}" == *".openstack.svc.cluster.local" ]] || \
           [[ "${domain}" == *".openstack.svc" ]] || \
           [[ "${domain}" == *".openstack" ]]; then
            continue
        fi
        echo "        ${domain}" >> "${NGINX_CONFIG}"
    done

    # 配置代理设置 - 仅使用IPv4后端
    cat >> "${NGINX_CONFIG}" << EOF;

    access_log /var/log/nginx/openstack-access.log;
    error_log /var/log/nginx/openstack-error.log;

    location / {
        proxy_pass http://${PUBLIC_OPENSTACK_IP};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # 对于大文件上传（如镜像）
        client_max_body_size 0;
        proxy_read_timeout 600s;
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
    }
}

# HTTPS代理配置
server {
    listen 443 ssl;
    listen [::]:443 ssl ipv6only=on;

    # 匹配所有OpenStack相关域名
    server_name
EOF

    # 添加域名匹配规则（与HTTP相同）
    echo "        # 正则匹配" >> "${NGINX_CONFIG}"
    echo "        ~^.*\.openstack\.svc\.cluster\.local$" >> "${NGINX_CONFIG}"
    echo "        ~^.*\.openstack\.svc$" >> "${NGINX_CONFIG}"
    echo "        ~^.*\.openstack$" >> "${NGINX_CONFIG}"

    # 添加各服务名称（与HTTP相同）
    echo "        # 服务名称" >> "${NGINX_CONFIG}"
    cat "${OUTPUT_DIR}/domains.txt" | while read domain; do
        # 跳过空行和已经通过正则匹配的域
        [ -z "$domain" ] && continue
        if [[ "${domain}" == *".openstack.svc.cluster.local" ]] || \
           [[ "${domain}" == *".openstack.svc" ]] || \
           [[ "${domain}" == *".openstack" ]]; then
            continue
        fi
        echo "        ${domain}" >> "${NGINX_CONFIG}"
    done

    # 配置TLS和代理设置 - 仅使用IPv4后端
    cat >> "${NGINX_CONFIG}" << EOF;

    # 自签名证书
    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;

    # SSL配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH';

    access_log /var/log/nginx/openstack-ssl-access.log;
    error_log /var/log/nginx/openstack-ssl-error.log;

    location / {
        proxy_pass https://${PUBLIC_OPENSTACK_IP};
        proxy_ssl_verify off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # 对于大文件上传（如镜像）
        client_max_body_size 0;
        proxy_read_timeout 600s;
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
    }
}

# 特定端口代理（按照服务类型分组）
EOF

    # 添加端口代理配置，按分组添加不同的端口
    if [ -s "${OUTPUT_DIR}/ports.txt" ]; then
        # 需要排除的标准Web端口
        echo "# API服务端口代理" >> "${NGINX_CONFIG}"

        cat >> "${NGINX_CONFIG}" << EOF
# 身份认证服务端口 (Keystone)
server {
    listen 5000;
    listen [::]:5000 ipv6only=on;
    server_name _;

    access_log /var/log/nginx/openstack-keystone-access.log;
    error_log /var/log/nginx/openstack-keystone-error.log;

    location / {
        proxy_pass http://${PUBLIC_OPENSTACK_IP}:5000;
        proxy_set_header Host \$host:5000;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 0;
        proxy_read_timeout 600s;
    }
}

# 镜像服务端口 (Glance)
server {
    listen 9292;
    listen [::]:9292 ipv6only=on;
    server_name _;

    access_log /var/log/nginx/openstack-glance-access.log;
    error_log /var/log/nginx/openstack-glance-error.log;

    location / {
        proxy_pass http://${PUBLIC_OPENSTACK_IP}:9292;
        proxy_set_header Host \$host:9292;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 0;
        proxy_read_timeout 1800s; # 镜像上传可能需要更长时间
    }
}

# 计算服务端口 (Nova)
server {
    listen 8774;
    listen [::]:8774 ipv6only=on;
    server_name _;

    access_log /var/log/nginx/openstack-nova-access.log;
    error_log /var/log/nginx/openstack-nova-error.log;

    location / {
        proxy_pass http://${PUBLIC_OPENSTACK_IP}:8774;
        proxy_set_header Host \$host:8774;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 0;
        proxy_read_timeout 600s;
    }
}

# 资源放置服务端口 (Placement)
server {
    listen 8778;
    listen [::]:8778 ipv6only=on;
    server_name _;

    location / {
        proxy_pass http://${PUBLIC_OPENSTACK_IP}:8778;
        proxy_set_header Host \$host:8778;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 0;
        proxy_read_timeout 600s;
    }
}

# 其他所有服务端口
server {
EOF

        # 添加其他服务端口监听 - 排除已经单独配置的端口和标准Web端口
        cat "${OUTPUT_DIR}/ports.txt" | grep -v -E '^(80|443|5000|8774|8778|9292)$' | while read port; do
            [ -z "$port" ] && continue
            echo "    listen ${port};" >> "${NGINX_CONFIG}"
            echo "    listen [::]:${port} ipv6only=on;" >> "${NGINX_CONFIG}"
        done

        cat >> "${NGINX_CONFIG}" << EOF
    server_name _;  # 匹配所有主机名

    access_log /var/log/nginx/openstack-other-ports-access.log;
    error_log /var/log/nginx/openstack-other-ports-error.log;

    location / {
        proxy_pass http://${PUBLIC_OPENSTACK_IP}:\$server_port;
        proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # 对于大文件上传（如镜像）
        client_max_body_size 0;
        proxy_read_timeout 600s;
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
    }
}
EOF
    fi

    echo "nginx配置已生成到 ${NGINX_CONFIG}"
}

# 部署nginx配置
deploy_nginx_config() {
    # 备份现有配置
    backup_config "nginx" "${NGINX_INSTALL_PATH}"

    echo "正在安装nginx..."
    apt update && apt install -y nginx || {
        echo "错误: 无法安装nginx，请手动安装"
        return 1
    }

    echo "创建SSL证书目录..."
    mkdir -p /etc/nginx/ssl

    # 生成自签名证书（如果不存在）
    if [ ! -f "/etc/nginx/ssl/nginx.crt" ]; then
        echo "生成自签名SSL证书..."
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/nginx/ssl/nginx.key \
            -out /etc/nginx/ssl/nginx.crt \
            -subj "/CN=openstack-proxy"
    fi

    echo "部署nginx配置..."
    cp "${NGINX_CONFIG}" "${NGINX_INSTALL_PATH}"

    # 启用配置
    if [ ! -L "${NGINX_ENABLED_PATH}" ]; then
        ln -sf "${NGINX_INSTALL_PATH}" "${NGINX_ENABLED_PATH}"
    fi

    # 禁用默认配置（如果存在）
    if [ -L "/etc/nginx/sites-enabled/default" ]; then
        rm -f "/etc/nginx/sites-enabled/default"
    fi

    echo "检查nginx配置语法..."
    nginx -t || {
        echo "错误: nginx配置语法检查失败，请手动检查配置"
        return 1
    }

    echo "重启nginx服务..."
    systemctl restart nginx
    systemctl enable nginx

    echo "nginx配置已部署"
    return 0
}

# 主函数
main() {
    echo "===== OpenStack Nginx代理配置生成工具 ====="
    echo "代理服务器IPv4: ${PROXY_IPV4}"
    echo "代理服务器IPv6: ${PROXY_IPV6}"
    echo "OpenStack服务IP: ${PUBLIC_OPENSTACK_IP}"
    echo "输出目录: ${OUTPUT_DIR}"
    echo "==========================================="

    # 检查依赖
    check_dependencies || exit 1

    # 收集数据，如果文件不存在
    if [ ! -f "${OUTPUT_DIR}/services.json" ] || [ ! -f "${OUTPUT_DIR}/domains.txt" ] || [ ! -f "${OUTPUT_DIR}/ports.txt" ]; then
        collect_openstack_data
    fi

    # 生成配置
    generate_nginx_config

    # 询问是否部署
    echo "是否要部署nginx配置? (y/n)"
    read deploy_answer

    if [ "${deploy_answer}" = "y" ] || [ "${deploy_answer}" = "Y" ]; then
        deploy_nginx_config

        # 显示验证命令
        echo "验证Nginx配置:"
        echo "  curl -4 http://${PROXY_IPV4}/v3"
        echo "  curl -6 http://[${PROXY_IPV6}]/v3"
    else
        echo "配置未部署，仅生成文件。"
    fi

    echo "Nginx配置脚本执行完成。"
}

# 运行主函数
main