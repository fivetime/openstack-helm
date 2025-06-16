#!/bin/bash

set -e

KEY_NAME="octavia_ssh_key"
KEY_DIR="./keys"
PRIVATE_KEY_FILE="${KEY_DIR}/${KEY_NAME}"
PUBLIC_KEY_FILE="${KEY_DIR}/${KEY_NAME}.pub"

# 创建密钥目录
mkdir -p "${KEY_DIR}"

# 检查密钥是否已存在
if [[ -f "${PRIVATE_KEY_FILE}" && -f "${PUBLIC_KEY_FILE}" ]]; then
    echo "SSH keys already exist:"
    echo "  Private key: ${PRIVATE_KEY_FILE}"
    echo "  Public key: ${PUBLIC_KEY_FILE}"
    exit 0
fi

echo "Generating SSH key pair for Octavia..."

# 生成 SSH 密钥对（使用现代 Ed25519 算法）
ssh-keygen -t ed25519 -f "${PRIVATE_KEY_FILE}" -N "" -C "octavia-amphora-key"

echo "SSH key pair generated successfully:"
echo "  Private key: ${PRIVATE_KEY_FILE}"
echo "  Public key: ${PUBLIC_KEY_FILE}"

# 显示公钥内容
echo ""
echo "Public key content:"
cat "${PUBLIC_KEY_FILE}"

echo ""
echo "To use these keys with Octavia, add the following to your values.yaml:"
echo ""
echo "secrets:"
echo "  ssh_key:"
echo "    private_key: |"
sed 's/^/      /' "${PRIVATE_KEY_FILE}"
echo "    public_key: |"
sed 's/^/      /' "${PUBLIC_KEY_FILE}"

echo ""
echo "Copy the above configuration and paste it into your values.yaml file."