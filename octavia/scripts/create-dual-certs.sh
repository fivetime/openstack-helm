#!/bin/bash

set -xe

# 定义证书源路径 - 这是create_dual_intermediate_CA.sh生成的证书位置
CERT_SOURCE_PATH=${CERT_SOURCE_PATH:-"/tmp/dual_ca/etc/octavia/certs"}

# CA私钥密码 - 可以通过环境变量传递
CA_PASSPHRASE=${CA_PASSPHRASE:-"not-secure-passphrase"}

# 根据原始190-create-octavia-certs.sh的映射规则
# 定义要导入到Secret的证书文件映射
declare -A CERT_MAPPING=(
    ["ca_01.pem"]="client_ca.cert.pem"
    ["cakey.pem"]="server_ca.key.pem"
    ["client.pem"]="client.cert-and-key.pem"
)

function validate_certificates() {
    echo "验证证书文件是否存在..."

    local missing_files=()

    # 检查源证书文件是否都存在
    for cert_file in "${CERT_MAPPING[@]}"; do
        if [[ ! -f "${CERT_SOURCE_PATH}/${cert_file}" ]]; then
            missing_files+=("${CERT_SOURCE_PATH}/${cert_file}")
        fi
    done

    if [[ ${#missing_files[@]} -gt 0 ]]; then
        echo "错误：以下证书文件缺失："
        printf '%s\n' "${missing_files[@]}"
        echo ""
        echo "请确保已经运行create_dual_intermediate_CA.sh脚本生成证书，"
        echo "并且证书位于: ${CERT_SOURCE_PATH}"
        echo ""
        echo "预期的证书文件："
        for cert_file in "${CERT_MAPPING[@]}"; do
            echo "  - ${CERT_SOURCE_PATH}/${cert_file}"
        done
        exit 1
    fi

    echo "所有证书文件验证通过"
}

function validate_certificate_content() {
    echo "验证证书内容有效性..."

    # 验证客户端CA证书
    if ! openssl x509 -in "${CERT_SOURCE_PATH}/client_ca.cert.pem" -text -noout >/dev/null 2>&1; then
        echo "错误：client_ca.cert.pem 不是有效的证书文件"
        exit 1
    fi

    # 验证服务器CA私钥（使用密码）
    if ! openssl rsa -in "${CERT_SOURCE_PATH}/server_ca.key.pem" -check -noout -passin pass:"${CA_PASSPHRASE}" >/dev/null 2>&1; then
        echo "错误：server_ca.key.pem 不是有效的私钥文件，或密码错误"
        echo "请检查CA_PASSPHRASE环境变量是否正确"
        exit 1
    fi

    # 验证客户端证书和密钥文件
    if ! openssl x509 -in "${CERT_SOURCE_PATH}/client.cert-and-key.pem" -text -noout >/dev/null 2>&1; then
        echo "错误：client.cert-and-key.pem 不包含有效的证书"
        exit 1
    fi

    echo "证书内容验证通过"
}

function trim_data() {
    local data_path=$1
    if [[ ! -f "$data_path" ]]; then
        echo "错误：文件不存在: $data_path"
        exit 1
    fi
    cat "$data_path" | base64 -w0 | tr -d '\n'
}

function check_existing_secret() {
    echo "检查现有Secret..."

    if kubectl get secret octavia-certs --namespace openstack >/dev/null 2>&1; then
        echo "Secret 'octavia-certs' 已存在"

        # 检查现有Secret中的证书是否仍然有效（30天内不过期）
        echo "检查现有证书有效期..."

        # 获取现有证书并检查有效期
        if kubectl get secret octavia-certs --namespace openstack -o jsonpath='{.data.ca_01\.pem}' | base64 -d > /tmp/existing_cert.pem 2>/dev/null; then
            if openssl x509 -in /tmp/existing_cert.pem -checkend 2592000 -noout >/dev/null 2>&1; then
                echo "现有证书仍有效（30天内不会过期），跳过更新"
                rm -f /tmp/existing_cert.pem
                return 0
            else
                echo "现有证书即将过期，将更新证书"
            fi
            rm -f /tmp/existing_cert.pem
        fi

        echo "删除现有Secret以便更新..."
        kubectl delete secret octavia-certs --namespace openstack
    fi

    return 1
}

function create_secret() {
    echo "创建octavia-certs Secret..."

    # 创建临时目录用于准备证书文件
    local temp_dir=$(mktemp -d)
    trap "rm -rf ${temp_dir}" EXIT

    # 处理每个证书文件
    for secret_key in "${!CERT_MAPPING[@]}"; do
        source_file="${CERT_SOURCE_PATH}/${CERT_MAPPING[$secret_key]}"

        if [[ "$secret_key" == "cakey.pem" ]]; then
            # 对于server_ca.key.pem，需要去除密码保护
            echo "处理加密私钥: ${CERT_MAPPING[$secret_key]} -> ${secret_key}"
            openssl rsa -in "$source_file" -out "${temp_dir}/${secret_key}" -passin pass:"${CA_PASSPHRASE}"
        else
            # 其他文件直接复制
            cp "$source_file" "${temp_dir}/${secret_key}"
        fi

        echo "映射: ${CERT_MAPPING[$secret_key]} -> ${secret_key}"
    done

    # 生成Secret YAML并应用
    cat <<EOF | kubectl apply --namespace openstack -f -
---
apiVersion: v1
kind: Secret
metadata:
  name: octavia-certs
  namespace: openstack
  labels:
    app: octavia
    component: certificates
  annotations:
    octavia.openstack.org/cert-imported-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    octavia.openstack.org/cert-source: "create_dual_intermediate_CA.sh"
type: Opaque
data:
  ca_01.pem: $(trim_data "${temp_dir}/ca_01.pem")
  cakey.pem: $(trim_data "${temp_dir}/cakey.pem")
  client.pem: $(trim_data "${temp_dir}/client.pem")
EOF

    echo "Secret 'octavia-certs' 创建成功"
}

function display_certificate_info() {
    echo ""
    echo "=== 证书信息汇总 ==="

    # 显示客户端CA证书信息
    echo "客户端CA证书信息："
    openssl x509 -in "${CERT_SOURCE_PATH}/client_ca.cert.pem" -text -noout | grep -E "(Subject:|Not After:|Serial Number:)" | sed 's/^/  /'

    echo ""
    echo "服务器CA私钥信息："
    openssl rsa -in "${CERT_SOURCE_PATH}/server_ca.key.pem" -text -noout | grep -E "(Private-Key:|writing RSA key)" | sed 's/^/  /' || echo "  RSA 私钥文件"

    echo ""
    echo "客户端证书信息："
    openssl x509 -in "${CERT_SOURCE_PATH}/client.cert-and-key.pem" -text -noout | grep -E "(Subject:|Not After:|Serial Number:)" | sed 's/^/  /'

    echo ""
    echo "=== Secret文件映射 ==="
    for secret_key in "${!CERT_MAPPING[@]}"; do
        echo "  ${secret_key} <- ${CERT_MAPPING[$secret_key]}"
    done
    echo ""
}

function main() {
    echo "开始导入Octavia证书到Kubernetes Secret..."
    echo "证书源路径: ${CERT_SOURCE_PATH}"

    # 检查密码是否设置
    if [[ "${CA_PASSPHRASE}" == "not-secure-passphrase" ]]; then
        echo "警告：使用默认密码，请通过CA_PASSPHRASE环境变量设置正确的密码"
        echo "例如：export CA_PASSPHRASE='your-actual-password'"
    fi

    echo ""

    # 其余函数调用保持不变...
    validate_certificates
    validate_certificate_content
    display_certificate_info

    if check_existing_secret; then
        echo "证书导入完成（使用现有有效证书）"
        return 0
    fi

    create_secret

    echo ""
    echo "证书导入完成！"
    echo ""
    echo "可以使用以下命令验证："
    echo "  kubectl get secret octavia-certs -n openstack"
    echo "  kubectl describe secret octavia-certs -n openstack"
}

# 执行主函数
main "$@"