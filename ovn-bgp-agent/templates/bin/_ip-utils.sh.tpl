#!/bin/bash

# ============================================================================
# IP Address Utility Functions
# IP 地址处理工具函数集
# ============================================================================

# ----------------------------------------------------------------------------
# IPv4 Functions
# ----------------------------------------------------------------------------

# 判断 IPv4 是否为私网地址或保留地址（非公网可路由）
is_private_or_reserved_ipv4() {
    local ip="$1"
    local first second
    IFS='.' read -r first second _ _ <<< "$ip"

    # RFC 1918 私有地址
    [[ "$first" == "10" ]] && return 0                           # 10.0.0.0/8
    [[ "$first" == "172" && "$second" -ge 16 && "$second" -le 31 ]] && return 0  # 172.16.0.0/12
    [[ "$first" == "192" && "$second" == "168" ]] && return 0    # 192.168.0.0/16

    # 其他保留地址
    [[ "$first" == "127" ]] && return 0                          # 127.0.0.0/8 回环
    [[ "$first" == "169" && "$second" == "254" ]] && return 0    # 169.254.0.0/16 链路本地
    [[ "$first" == "100" && "$second" -ge 64 && "$second" -le 127 ]] && return 0  # 100.64.0.0/10 CGNAT

    return 1
}

# 获取网卡上所有 IPv4 地址
get_all_ipv4_addresses() {
    local interface="$1"

    ip -4 addr show dev "${interface}" 2>/dev/null | \
        grep -oP '(?<=inet\s)\d+(\.\d+){3}' | \
        grep -v '^127\.'  # 排除回环地址
}

# 检查 IP 是否在指定网段内
ip_in_subnet() {
    local ip="$1"
    local subnet="$2"

    # 使用 ipcalc（如果可用）
    if command -v ipcalc >/dev/null 2>&1; then
        ipcalc -c "$ip" "$subnet" >/dev/null 2>&1
        return $?
    fi

    # Shell 实现
    local network prefix
    IFS='/' read -r network prefix <<< "$subnet"

    # 转换为数字比较
    local ip_num network_num mask
    ip_num=$(printf '%d' $(echo "$ip" | awk -F. '{printf "0x%02x%02x%02x%02x", $1, $2, $3, $4}'))
    network_num=$(printf '%d' $(echo "$network" | awk -F. '{printf "0x%02x%02x%02x%02x", $1, $2, $3, $4}'))
    mask=$(( 0xFFFFFFFF << (32 - prefix) ))

    [[ $(( ip_num & mask )) -eq $(( network_num & mask )) ]]
}

# 根据配置的网段选择最佳 IPv4 地址
# 优先级: 1) 匹配配置网段 2) 私网地址 3) 公网地址
select_best_ipv4() {
    local interface="$1"
    local configured_subnets="$2"  # 可选：配置的网段列表（换行分隔）

    # 获取所有 IPv4 地址
    local all_ips
    all_ips=$(get_all_ipv4_addresses "$interface")

    if [ -z "$all_ips" ]; then
        echo "ERROR: No IPv4 address found on $interface" >&2
        return 1
    fi

    # 如果只有一个地址，直接返回
    local ip_count=$(echo "$all_ips" | wc -l)
    if [ "$ip_count" -eq 1 ]; then
        echo "$all_ips"
        return 0
    fi

    # 优先级1: 在配置网段内的地址（最佳匹配）
    if [ -n "$configured_subnets" ]; then
        while IFS= read -r subnet; do
            [ -z "$subnet" ] && continue
            while IFS= read -r ip; do
                if ip_in_subnet "$ip" "$subnet"; then
                    echo "$ip"
                    return 0
                fi
            done <<< "$all_ips"
        done <<< "$configured_subnets"
    fi

    # 优先级2: 私网或保留地址（不暴露公网 IP）
    while IFS= read -r ip; do
        if is_private_or_reserved_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi
    done <<< "$all_ips"

    # 优先级3: 返回第一个（公网地址）
    echo "$all_ips" | head -n1
    return 0
}

# ----------------------------------------------------------------------------
# IPv6 Functions
# ----------------------------------------------------------------------------

# 判断是否为 ULA 地址 (fc00::/7)
is_ula_address() {
    local addr="$1"
    [[ "$addr" =~ ^f[cd][0-9a-f]{2}: ]]
}

# 获取网卡上所有可用的 IPv6 地址（只要 GUA 和 ULA）
get_all_ipv6_addresses() {
    local interface="$1"

    ip -6 addr show dev "${interface}" 2>/dev/null | \
        grep inet6 | \
        grep -v "scope link" | \
        grep -E "inet6 ([23][0-9a-f]{3}:|f[cd][0-9a-f]{2}:)" | \
        awk '{print $2}' | \
        cut -d'/' -f1
}

# 检查两个 IPv6 地址是否在同一 /64 网段
ipv6_same_subnet() {
    local addr1="$1"
    local addr2="$2"

    # 比较前64位（前4组）
    local prefix1=$(echo "$addr1" | cut -d':' -f1-4)
    local prefix2=$(echo "$addr2" | cut -d':' -f1-4)

    [[ "$prefix1" == "$prefix2" ]]
}

# 验证 IPv6 地址格式（必须是 GUA 或 ULA）
validate_ipv6_format() {
    local addr="$1"

    # 必须是 GUA (2000::/3) 或 ULA (fc00::/7)
    if ! echo "$addr" | grep -qE "^([23][0-9a-f]{3}:|f[cd][0-9a-f]{2}:)"; then
        echo "ERROR: IPv6 must be GUA (2xxx:) or ULA (fcxx:/fdxx:): $addr" >&2
        return 1
    fi

    return 0
}

# 根据 peer IPv6 选择最佳本地 IPv6 地址
# 优先级: 1) 同网段 2) ULA 地址 3) GUA 地址
select_best_ipv6() {
    local interface="$1"
    local peer_ipv6="$2"

    # 获取所有可用 IPv6 地址
    local all_ipv6
    all_ipv6=$(get_all_ipv6_addresses "$interface")

    if [ -z "$all_ipv6" ]; then
        echo "ERROR: No GUA or ULA IPv6 address found on $interface" >&2
        return 1
    fi

    # 如果只有一个地址，直接返回
    local ipv6_count=$(echo "$all_ipv6" | wc -l)
    if [ "$ipv6_count" -eq 1 ]; then
        echo "$all_ipv6"
        return 0
    fi

    # 优先级1: 与 peer 同网段的地址（最匹配）
    while IFS= read -r addr; do
        if ipv6_same_subnet "$addr" "$peer_ipv6"; then
            echo "$addr"
            return 0
        fi
    done <<< "$all_ipv6"

    # 优先级2: ULA 地址（私网地址，不暴露交换机公网 IP）
    while IFS= read -r addr; do
        if is_ula_address "$addr"; then
            echo "$addr"
            return 0
        fi
    done <<< "$all_ipv6"

    # 优先级3: 返回第一个（通常是 GUA）
    echo "$all_ipv6" | head -n1
    return 0
}

# ----------------------------------------------------------------------------
# Common Functions
# ----------------------------------------------------------------------------

# 转换 IP 地址为 ASN
ip_to_asn() {
    local ip="$1"
    IFS='.' read -r a b c d <<< "$ip"
    echo $((4200000000 + b * 65536 + c * 256 + d))
}

# 测试 IPv4 连通性
test_ipv4_connectivity() {
    local target_ip="$1"
    local max_attempts="${2:-2}"

    ping -c "$max_attempts" -W 2 "$target_ip" >/dev/null 2>&1
}

# 测试 IPv6 连通性
test_ipv6_connectivity() {
    local target_ip="$1"
    local max_attempts="${2:-2}"

    ping6 -c "$max_attempts" -W 2 "$target_ip" >/dev/null 2>&1
}