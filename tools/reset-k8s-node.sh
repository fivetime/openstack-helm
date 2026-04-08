#!/usr/bin/env bash
# =============================================================================
# reset-k8s-node.sh — Kubernetes 节点重置脚本
#
# 将 K8s 节点恢复到加入集群前的干净状态。
# 自动检测容器运行时（containerd / CRI-O），执行对应的清理流程。
#
# 用法:
#   sudo bash reset-k8s-node.sh              交互式确认后执行
#   sudo bash reset-k8s-node.sh -y           跳过确认直接执行
#   sudo bash reset-k8s-node.sh --help       显示帮助
#   DRY_RUN=1 sudo bash reset-k8s-node.sh    仅预览，不执行
#
# 清理范围:
#   - kubeadm reset（含 etcd 数据）
#   - 所有容器和 Pod sandbox
#   - CNI 网络配置和插件（Cilium/Flannel/Calico 等）
#   - iptables/ip6tables 规则
#   - kubelet / kube-proxy / rook-ceph 残留
#   - 容器运行时缓存（镜像保留，容器/sandbox 清除）
#   - 容器日志
#
# 不清理:
#   - 容器运行时本身（containerd/CRI-O 保持安装状态）
#   - kubeadm/kubelet/kubectl 二进制
#   - 系统网络配置（/etc/hosts 等）
#   - 磁盘/OSD 数据（请使用 zap-disks.sh）
#
# 短链接: curl -fsSL https://tinyurl.com/reset-k8s-node | sudo bash
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------

DRY_RUN="${DRY_RUN:-0}"

# 清理模块定义
# 格式: ID|显示名称|描述|默认选中(1/0)|风险等级(低/中/高)
MODULES=(
    "kubelet|停止 kubelet|停止并禁用 kubelet 服务|1|低"
    "kubeadm|kubeadm reset|重置 kubeadm 配置（含 etcd 数据）|1|低"
    "containers|清理容器|删除所有容器和 Pod sandbox|1|低"
    "images|清理镜像|删除已下载的 K8s 容器镜像|0|中"
    "iptables|清理 iptables|清空 iptables/ip6tables 所有规则|0|高"
    "ipvs|清理 IPVS|清空 IPVS 负载均衡规则|0|中"
    "network|清理网络接口|删除 CNI 创建的虚拟网络接口|0|高"
    "runtime|重置容器运行时|清理运行时状态缓存|1|中"
    "runtime_config|重置运行时配置|重新生成 containerd/CRI-O 默认配置|0|中"
    "directories|清理目录|删除 K8s/CNI/rook 等相关目录|1|低"
)

# 启用的模块集合（在交互式选择后填充）
declare -A ENABLED_MODULES=()

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------

readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly GREEN='\033[0;32m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

log()  { echo -e "[$(date -u +'%F %T')] ${GREEN}INFO${NC}  $*" >&2; }
warn() { echo -e "[$(date -u +'%F %T')] ${YELLOW}WARN${NC}  $*" >&2; }
err()  { echo -e "[$(date -u +'%F %T')] ${RED}ERROR${NC} $*" >&2; }
die()  { err "$@"; exit 1; }

step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo >&2
    echo -e "${CYAN}[${STEP_NUM}/${STEP_TOTAL}]${NC} $*" >&2
}

# ---------------------------------------------------------------------------
# 帮助
# ---------------------------------------------------------------------------

show_usage() {
    cat >&2 <<EOF
用法: $(basename "$0") [选项]

将 Kubernetes 节点恢复到加入集群前的干净状态。

选项:
  -y, --yes     跳过确认，使用默认模块直接执行
  -a, --all     选择所有模块（含高风险项）并跳过确认
  -h, --help    显示此帮助信息

环境变量:
  DRY_RUN=1     仅预览操作，不实际执行

清理模块:
  kubelet       停止并禁用 kubelet             [默认]
  kubeadm       kubeadm reset                  [默认]
  containers    清理所有容器和 Pod sandbox      [默认]
  images        清理已下载的 K8s 容器镜像       [需手动选择]
  iptables      清空 iptables/ip6tables 规则   [需手动选择 ⚠️ 可能断网]
  ipvs          清空 IPVS 规则                 [需手动选择]
  network       清理 CNI 虚拟网络接口           [需手动选择 ⚠️ 可能断网]
  runtime       重置容器运行时状态              [默认]
  runtime_config 重新生成运行时默认配置         [需手动选择]
  directories   清理 K8s/CNI/rook 等目录        [默认]

示例:
  $(basename "$0")                  交互式选择模块后执行
  $(basename "$0") -y               使用默认模块直接执行
  $(basename "$0") -a               所有模块全选直接执行
  DRY_RUN=1 $(basename "$0")        仅预览，不执行
EOF
}

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------

check_root() {
    [[ $EUID -eq 0 ]] || die "必须以 root 身份运行"
}

# ---------------------------------------------------------------------------
# 运行时检测
# ---------------------------------------------------------------------------

# 检测 K8s 使用的 CRI 运行时以及其他独立运行的容器运行时
detect_runtime() {
    CRI_RUNTIME=""
    CRI_SOCKET=""
    # 记录所有运行中的容器运行时
    CONTAINERD_RUNNING=false
    CRIO_RUNNING=false

    # 检测哪些运行时正在运行
    systemctl is-active containerd >/dev/null 2>&1 && CONTAINERD_RUNNING=true
    systemctl is-active crio >/dev/null 2>&1 && CRIO_RUNNING=true

    # 优先从 kubelet 配置确定 K8s 使用的 CRI
    if [[ -f /var/lib/kubelet/kubeadm-flags.env ]]; then
        local configured_socket
        configured_socket=$(grep -oP '(?<=--container-runtime-endpoint=)\S+' \
            /var/lib/kubelet/kubeadm-flags.env 2>/dev/null || true)
        if [[ -n "$configured_socket" ]]; then
            if [[ "$configured_socket" == *"containerd"* ]]; then
                CRI_RUNTIME="containerd"
                CRI_SOCKET="$configured_socket"
            elif [[ "$configured_socket" == *"crio"* || "$configured_socket" == *"cri-o"* ]]; then
                CRI_RUNTIME="cri-o"
                CRI_SOCKET="$configured_socket"
            fi
        fi
    fi

    # fallback: 用运行中的服务推断
    if [[ -z "$CRI_RUNTIME" ]]; then
        if [[ "$CRIO_RUNNING" == "true" ]]; then
            CRI_RUNTIME="cri-o"
            CRI_SOCKET="unix:///var/run/crio/crio.sock"
        elif [[ "$CONTAINERD_RUNNING" == "true" ]]; then
            CRI_RUNTIME="containerd"
            CRI_SOCKET="unix:///var/run/containerd/containerd.sock"
        fi
    fi

    # fallback: 检测 socket 文件
    if [[ -z "$CRI_RUNTIME" ]]; then
        if [[ -S /var/run/crio/crio.sock ]]; then
            CRI_RUNTIME="cri-o"
            CRI_SOCKET="unix:///var/run/crio/crio.sock"
        elif [[ -S /var/run/containerd/containerd.sock ]]; then
            CRI_RUNTIME="containerd"
            CRI_SOCKET="unix:///var/run/containerd/containerd.sock"
        fi
    fi

    if [[ -z "$CRI_RUNTIME" ]]; then
        warn "未检测到容器运行时（containerd/CRI-O），将跳过运行时相关清理"
    fi

    # 检测独立运行时（非 K8s CRI 用途）
    OTHER_RUNTIMES=()
    if [[ "$CRI_RUNTIME" == "cri-o" && "$CONTAINERD_RUNNING" == "true" ]]; then
        OTHER_RUNTIMES+=("containerd")
    fi
    if [[ "$CRI_RUNTIME" == "containerd" && "$CRIO_RUNNING" == "true" ]]; then
        OTHER_RUNTIMES+=("cri-o")
    fi
}

# ---------------------------------------------------------------------------
# 节点信息收集
# ---------------------------------------------------------------------------

show_node_info() {
    log "节点信息:"
    log "  主机名:     $(hostname)"
    log "  K8s CRI:    ${CRI_RUNTIME:-未检测到} (${CRI_SOCKET:-N/A})"

    if [[ ${#OTHER_RUNTIMES[@]} -gt 0 ]]; then
        log "  其他运行时: ${OTHER_RUNTIMES[*]}（非 K8s 用途，不会被清理）"
    fi

    # kubelet 状态
    local kubelet_status
    if systemctl list-unit-files kubelet.service >/dev/null 2>&1; then
        kubelet_status=$(systemctl is-active kubelet 2>/dev/null || true)
        [[ -z "$kubelet_status" ]] && kubelet_status="unknown"
    else
        kubelet_status="未安装"
    fi
    log "  kubelet:    $kubelet_status"

    # 容器/Pod 数量
    if command -v crictl >/dev/null 2>&1 && [[ -n "$CRI_SOCKET" ]]; then
        local container_count pod_count
        container_count=$(crictl --runtime-endpoint "$CRI_SOCKET" ps -a 2>/dev/null | tail -n +2 | wc -l || echo "?")
        pod_count=$(crictl --runtime-endpoint "$CRI_SOCKET" pods 2>/dev/null | tail -n +2 | wc -l || echo "?")
        log "  K8s 容器:   $container_count"
        log "  K8s Pod:    $pod_count"
    fi

    # 如果 containerd 不是 K8s CRI 但在运行，显示其中的容器数
    if [[ "$CRI_RUNTIME" != "containerd" && "$CONTAINERD_RUNNING" == "true" ]]; then
        if command -v ctr >/dev/null 2>&1; then
            local non_k8s_count
            non_k8s_count=$(ctr -n default containers list -q 2>/dev/null | wc -l || echo "?")
            log "  containerd 本地容器: $non_k8s_count（不会被清理）"
        fi
    fi

    # K8s 版本
    if command -v kubelet >/dev/null 2>&1; then
        local k8s_ver
        k8s_ver=$(kubelet --version 2>/dev/null | awk '{print $2}' || echo "?")
        log "  K8s 版本:   $k8s_ver"
    fi
}

# ---------------------------------------------------------------------------
# 交互式模块选择
# ---------------------------------------------------------------------------

select_modules() {
    local mode="${1:-}"

    # -a/--all: 全选并跳过确认
    if [[ "$mode" == "-a" || "$mode" == "--all" ]]; then
        for mod in "${MODULES[@]}"; do
            local id
            id=$(echo "$mod" | cut -d'|' -f1)
            ENABLED_MODULES["$id"]=1
        done
        return 0
    fi

    # -y/--yes: 使用默认选择并跳过确认
    if [[ "$mode" == "-y" || "$mode" == "--yes" ]]; then
        for mod in "${MODULES[@]}"; do
            local id default_on
            id=$(echo "$mod" | cut -d'|' -f1)
            default_on=$(echo "$mod" | cut -d'|' -f4)
            [[ "$default_on" == "1" ]] && ENABLED_MODULES["$id"]=1
        done
        return 0
    fi

    # 交互式选择
    echo >&2
    log "清理模块选择:"
    echo >&2

    # 使用数组跟踪选中状态
    local -a selected=()
    for mod in "${MODULES[@]}"; do
        local default_on
        default_on=$(echo "$mod" | cut -d'|' -f4)
        selected+=("$default_on")
    done

    # 显示模块列表
    local i
    for i in "${!MODULES[@]}"; do
        local mod="${MODULES[$i]}"
        local name desc risk
        name=$(echo "$mod" | cut -d'|' -f2)
        desc=$(echo "$mod" | cut -d'|' -f3)
        risk=$(echo "$mod" | cut -d'|' -f5)

        local check_mark risk_label
        if [[ "${selected[$i]}" == "1" ]]; then
            check_mark="${GREEN}✔${NC}"
        else
            check_mark=" "
        fi

        case "$risk" in
            高) risk_label=" ${RED}⚠️ 高风险${NC}";;
            中) risk_label=" ${YELLOW}[中]${NC}";;
            *)  risk_label="";;
        esac

        echo -e "  $((i + 1)))  [${check_mark}]  ${name} — ${desc}${risk_label}" >&2
    done

    echo >&2
    printf "  ${GREEN}操作:${NC} 输入编号切换选中状态（如 4,5,6）    ${GREEN}确认:${NC} Enter    ${GREEN}全选:${NC} A    ${GREEN}退出:${NC} q\n" >&2
    echo >&2

    local input
    read -rep "请选择（直接 Enter 使用默认）: " input </dev/tty

    # 退出
    if [[ "$input" == "q" || "$input" == "Q" ]]; then
        log "用户取消操作"
        exit 0
    fi

    # 全选
    if [[ "$input" == "a" || "$input" == "A" ]]; then
        for i in "${!selected[@]}"; do
            selected[$i]=1
        done
    elif [[ -n "$input" ]]; then
        # 切换指定编号的选中状态
        input="${input//,/ }"
        for num in $input; do
            if ! [[ "$num" =~ ^[0-9]+$ ]]; then
                die "无效的编号: $num"
            fi
            local idx=$((num - 1))
            if [[ $idx -lt 0 || $idx -ge ${#MODULES[@]} ]]; then
                die "编号超出范围: $num（有效范围: 1-${#MODULES[@]}）"
            fi
            # 切换
            if [[ "${selected[$idx]}" == "1" ]]; then
                selected[$idx]=0
            else
                selected[$idx]=1
            fi
        done
    fi
    # 空输入 = 使用当前默认

    # 检查是否选了任何模块
    local any_selected=false
    for s in "${selected[@]}"; do
        [[ "$s" == "1" ]] && any_selected=true
    done
    if [[ "$any_selected" == "false" ]]; then
        die "未选择任何模块"
    fi

    # 显示最终选择
    echo >&2
    local has_high_risk=false
    warn "即将执行以下清理模块:"
    for i in "${!MODULES[@]}"; do
        if [[ "${selected[$i]}" == "1" ]]; then
            local mod="${MODULES[$i]}"
            local name risk
            name=$(echo "$mod" | cut -d'|' -f2)
            risk=$(echo "$mod" | cut -d'|' -f5)
            if [[ "$risk" == "高" ]]; then
                warn "  ${RED}⚠️${NC}  $name ${RED}(高风险)${NC}"
                has_high_risk=true
            else
                warn "  ✔  $name"
            fi
        fi
    done

    # 确认
    echo >&2
    if [[ "$has_high_risk" == "true" ]]; then
        warn "包含高风险操作，可能导致网络中断！"
    fi

    local confirm
    read -rep "确认执行？输入 YES 继续: " confirm </dev/tty
    if [[ "$confirm" != "YES" ]]; then
        log "用户取消操作"
        exit 0
    fi

    # 写入 ENABLED_MODULES
    for i in "${!MODULES[@]}"; do
        if [[ "${selected[$i]}" == "1" ]]; then
            local id
            id=$(echo "${MODULES[$i]}" | cut -d'|' -f1)
            ENABLED_MODULES["$id"]=1
        fi
    done
}

# 检查模块是否启用
is_enabled() {
    [[ -n "${ENABLED_MODULES[$1]+_}" ]]
}

# ---------------------------------------------------------------------------
# dry-run 包装
# ---------------------------------------------------------------------------

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY-RUN] $*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# 清理步骤
# ---------------------------------------------------------------------------

stop_kubelet() {
    step "停止 kubelet"
    if systemctl is-active kubelet >/dev/null 2>&1; then
        run systemctl stop kubelet
        run systemctl disable kubelet 2>/dev/null || true
        log "kubelet 已停止"
    else
        log "kubelet 未运行，跳过"
    fi
}

run_kubeadm_reset() {
    step "执行 kubeadm reset"
    if command -v kubeadm >/dev/null 2>&1; then
        if [[ -n "$CRI_SOCKET" ]]; then
            run kubeadm reset -f --cri-socket "$CRI_SOCKET"
        else
            run kubeadm reset -f
        fi
        log "kubeadm reset 完成"
    else
        warn "kubeadm 未安装，跳过"
    fi
}

cleanup_containers() {
    step "清理容器和 Pod sandbox"
    if command -v crictl >/dev/null 2>&1 && [[ -n "$CRI_SOCKET" ]]; then
        export CONTAINER_RUNTIME_ENDPOINT="$CRI_SOCKET"

        # 停止所有运行中的容器
        local running
        running=$(crictl ps -q 2>/dev/null || true)
        if [[ -n "$running" ]]; then
            log "停止运行中的容器..."
            run bash -c "crictl ps -q 2>/dev/null | xargs -r crictl stop 2>/dev/null || true"
        fi

        # 删除所有容器
        run bash -c "crictl rm --all --force 2>/dev/null || true"
        # 删除所有 Pod sandbox
        run bash -c "crictl rmp --all --force 2>/dev/null || true"

        log "容器和 Pod sandbox 已清理"
    else
        warn "crictl 未安装或无运行时，跳过容器清理"
    fi
}

cleanup_images() {
    step "清理 K8s 容器镜像"
    if [[ -z "$CRI_RUNTIME" ]]; then
        warn "未检测到容器运行时，跳过"
        return 0
    fi

    case "$CRI_RUNTIME" in
        containerd)
            if command -v ctr >/dev/null 2>&1; then
                # 只清理 k8s.io 命名空间，不动 default 命名空间
                local image_count
                image_count=$(ctr -n k8s.io images list -q 2>/dev/null | wc -l || echo 0)
                log "k8s.io 命名空间中有 $image_count 个镜像"

                # 1. 删除镜像引用
                if [[ "$image_count" -gt 0 ]]; then
                    run bash -c "ctr -n k8s.io images list -q 2>/dev/null | xargs -r ctr -n k8s.io images rm 2>/dev/null || true"
                fi

                # 2. 清理 content（底层 blob/layer 数据，释放磁盘空间）
                local content_count
                content_count=$(ctr -n k8s.io content list -q 2>/dev/null | wc -l || echo 0)
                if [[ "$content_count" -gt 0 ]]; then
                    log "清理 k8s.io content 层（$content_count 个对象）..."
                    run bash -c "ctr -n k8s.io content list -q 2>/dev/null | xargs -r ctr -n k8s.io content rm 2>/dev/null || true"
                fi

                # 3. 清理 snapshots
                run bash -c "ctr -n k8s.io snapshots rm --all 2>/dev/null || true"

            elif command -v crictl >/dev/null 2>&1; then
                run bash -c "crictl --runtime-endpoint '$CRI_SOCKET' rmi --all 2>/dev/null || true"
            fi
            ;;
        cri-o)
            if command -v crictl >/dev/null 2>&1; then
                local image_count
                image_count=$(crictl --runtime-endpoint "$CRI_SOCKET" images -q 2>/dev/null | wc -l || echo 0)
                log "CRI-O 中有 $image_count 个镜像"
                run bash -c "crictl --runtime-endpoint '$CRI_SOCKET' rmi --all 2>/dev/null || true"
            fi
            # CRI-O 的 image store 底层数据随镜像删除自动清理
            ;;
    esac

    log "K8s 容器镜像已清理"
}

cleanup_iptables() {
    step "清理 iptables/ip6tables 规则"
    if command -v iptables >/dev/null 2>&1; then
        run iptables -F
        run iptables -t nat -F
        run iptables -t mangle -F
        run iptables -X 2>/dev/null || true
        log "iptables 已清理"
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        run ip6tables -F
        run ip6tables -t nat -F
        run ip6tables -t mangle -F
        run ip6tables -X 2>/dev/null || true
        log "ip6tables 已清理"
    fi
}

cleanup_ipvs() {
    step "清理 IPVS 规则"
    if command -v ipvsadm >/dev/null 2>&1; then
        run ipvsadm --clear
        log "IPVS 规则已清理"
    else
        log "ipvsadm 未安装，跳过"
    fi
}

cleanup_network_interfaces() {
    step "清理残留网络接口"
    local ifaces_to_delete=(
        "cilium_host" "cilium_net" "cilium_vxlan" "lxc_health"
        "flannel.1" "cni0" "kube-bridge" "kube-ipvs0"
        "vxlan.calico" "tunl0@NONE"
    )

    for iface in "${ifaces_to_delete[@]}"; do
        local clean_name="${iface%%@*}"
        if ip link show "$clean_name" >/dev/null 2>&1; then
            run ip link set "$clean_name" down 2>/dev/null || true
            run ip link delete "$clean_name" 2>/dev/null || true
            log "已删除网络接口: $clean_name"
        fi
    done

    # 清理所有 veth/lxc 开头的接口（CNI 创建的）
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        run ip link delete "$iface" 2>/dev/null || true
    done < <(ip -o link show 2>/dev/null | grep -oP '(?<=: )(veth|lxc)[^@:]+' || true)

    log "网络接口清理完成"
}

cleanup_directories() {
    step "清理 K8s 相关目录"

    # 先卸载可能存在的 bind mount（Cilium cgroupv2、kubelet 等）
    local mount_prefixes=(
        /var/run/cilium
        /run/cilium
        /var/lib/kubelet
    )
    for prefix in "${mount_prefixes[@]}"; do
        # 按挂载深度倒序卸载，避免 busy
        while IFS= read -r mnt; do
            [[ -z "$mnt" ]] && continue
            run umount -l "$mnt" 2>/dev/null || true
        done < <(findmnt -rno TARGET 2>/dev/null | grep "^${prefix}" | sort -r)
    done

    local dirs=(
        # CNI
        /etc/cni/net.d
        /opt/cni/bin
        /var/lib/cni
        /run/flannel
        # Cilium
        /var/run/cilium
        /var/lib/cilium
        /run/cilium
        # Kubernetes
        /etc/kubernetes
        /var/lib/etcd
        /var/lib/kubelet
        /var/lib/kube-proxy
        # Rook-Ceph 残留（不含 OSD 数据）
        /var/lib/rook
        # 容器日志
        /var/log/containers
        /var/log/pods
    )

    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            run rm -rf "${dir:?}"/* 2>/dev/null || true
            log "已清理: $dir"
        fi
    done

    # kubeconfig
    if [[ -f "$HOME/.kube/config" ]]; then
        run rm -f "$HOME/.kube/config"
        log "已清理: ~/.kube/config"
    fi
}

restart_runtime() {
    step "重置容器运行时（仅 K8s CRI 部分）"
    if [[ -z "$CRI_RUNTIME" ]]; then
        warn "未检测到容器运行时，跳过"
        return 0
    fi

    case "$CRI_RUNTIME" in
        containerd)
            # containerd 可能同时被 K8s 和本地容器使用
            # 只清理 K8s CRI 插件管理的状态，不影响其他命名空间
            log "清理 containerd K8s CRI 状态..."

            if command -v ctr >/dev/null 2>&1; then
                # 清理 k8s.io 命名空间中的容器和任务
                run bash -c "ctr -n k8s.io tasks kill --all 2>/dev/null || true"
                run bash -c "ctr -n k8s.io tasks rm --all 2>/dev/null || true"
                run bash -c "ctr -n k8s.io containers rm \$(ctr -n k8s.io containers list -q 2>/dev/null) 2>/dev/null || true"
                # 清理 k8s.io 命名空间的快照（不动 default 命名空间）
                run bash -c "ctr -n k8s.io snapshots rm --all 2>/dev/null || true"
            fi

            # 清理 CRI 插件状态目录
            run rm -rf /var/lib/containerd/io.containerd.grpc.v1.cri/sandboxes/*
            run rm -rf /var/lib/containerd/io.containerd.grpc.v1.cri/containers/*

            # 注意: 不重启 containerd，避免中断非 K8s 容器
            # 如果 containerd 仅用于 K8s（没有其他运行时），可以安全重启
            if [[ ${#OTHER_RUNTIMES[@]} -eq 0 && "$CONTAINERD_RUNNING" == "true" ]]; then
                # 仅当 containerd 是唯一运行时时才重启
                # 检查是否有非 K8s 容器在运行
                local non_k8s_containers=0
                if command -v ctr >/dev/null 2>&1; then
                    non_k8s_containers=$(ctr -n default containers list -q 2>/dev/null | wc -l || echo 0)
                fi
                if [[ "$non_k8s_containers" -eq 0 ]]; then
                    log "containerd 无非 K8s 容器，执行完整重启..."
                    run systemctl restart containerd
                else
                    warn "检测到 $non_k8s_containers 个非 K8s 容器，跳过 containerd 重启"
                fi
            else
                log "containerd 有独立用途，跳过重启（仅清理 K8s 状态）"
            fi
            ;;
        cri-o)
            # CRI-O 专为 K8s 设计，可以安全完整重置
            log "重置 CRI-O..."
            run systemctl stop crio
            run rm -rf /var/lib/containers/storage/overlay-containers/*
            run rm -rf /var/run/crio/*
            run systemctl start crio
            ;;
    esac

    # 等待 CRI 运行时就绪
    if [[ "$DRY_RUN" != "1" ]]; then
        local svc_name
        svc_name=$( [[ "$CRI_RUNTIME" == "cri-o" ]] && echo crio || echo containerd )
        log "等待 ${CRI_RUNTIME} 就绪..."
        local retries=10
        while [[ $retries -gt 0 ]]; do
            if systemctl is-active "$svc_name" >/dev/null 2>&1; then
                break
            fi
            sleep 1
            retries=$((retries - 1))
        done
        if [[ $retries -eq 0 ]]; then
            warn "${CRI_RUNTIME} 未能在 10 秒内就绪"
        fi
    fi

    log "${CRI_RUNTIME} K8s CRI 状态已清理"
}

reset_runtime_config() {
    step "重置容器运行时配置"
    if [[ -z "$CRI_RUNTIME" ]]; then
        warn "未检测到容器运行时，跳过"
        return 0
    fi

    case "$CRI_RUNTIME" in
        containerd)
            local config="/etc/containerd/config.toml"
            if [[ -f "$config" ]]; then
                log "备份当前配置: ${config}.bak.$(date +%Y%m%d%H%M%S)"
                run cp "$config" "${config}.bak.$(date +%Y%m%d%H%M%S)"
            fi

            log "生成 containerd 默认配置..."
            run bash -c "containerd config default > '$config'"

            # K8s 推荐: 启用 SystemdCgroup
            if [[ "$DRY_RUN" != "1" ]] && [[ -f "$config" ]]; then
                sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$config"
                log "已启用 SystemdCgroup = true"
            fi

            # 重启 containerd 使配置生效
            run systemctl restart containerd
            log "containerd 配置已重置并重启"
            ;;
        cri-o)
            # CRI-O drop-in 配置在 /etc/crio/crio.conf.d/
            # 10-crio.conf 通常是包管理器安装的基础 runtime 配置（crun/runc），不能删
            # K8s/用户自定义配置一般用更高编号（如 20-*.conf, 99-*.conf）
            local dropin_dir="/etc/crio/crio.conf.d"
            if [[ -d "$dropin_dir" ]]; then
                # 列出非包管理器的配置文件（排除 10-crio.conf）
                local custom_confs
                custom_confs=$(find "$dropin_dir" -type f -name '*.conf' \
                    ! -name '10-crio.conf' 2>/dev/null)

                if [[ -n "$custom_confs" ]]; then
                    local bak_dir="${dropin_dir}.bak.$(date +%Y%m%d%H%M%S)"
                    log "备份自定义 CRI-O drop-in 配置到 $bak_dir ..."
                    run mkdir -p "$bak_dir"
                    while IFS= read -r conf; do
                        run cp "$conf" "$bak_dir/"
                        run rm -f "$conf"
                        log "  已清理: $(basename "$conf")"
                    done <<< "$custom_confs"
                else
                    log "无自定义 CRI-O drop-in 配置（10-crio.conf 为包管理器默认，保留）"
                fi

                # 显示保留的配置
                local remaining
                remaining=$(ls "$dropin_dir"/*.conf 2>/dev/null | xargs -r -n1 basename)
                if [[ -n "$remaining" ]]; then
                    log "保留的配置: $remaining"
                fi
            fi

            run systemctl restart crio
            log "CRI-O 配置已重置并重启"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 验证
# ---------------------------------------------------------------------------

verify_reset() {
    step "验证清理结果"
    echo >&2
    local all_clean=true

    # 运行时状态
    if [[ -n "$CRI_RUNTIME" ]]; then
        local svc_name
        svc_name=$( [[ "$CRI_RUNTIME" == "cri-o" ]] && echo crio || echo containerd )
        local rt_status
        rt_status=$(systemctl is-active "$svc_name" 2>/dev/null || echo "未知")
        if [[ "$rt_status" == "active" ]]; then
            log "  ✅ ${CRI_RUNTIME}: 运行中"
        else
            warn "  ❌ ${CRI_RUNTIME}: $rt_status"
            all_clean=false
        fi
    fi

    # kubelet 状态（清理后应该是 inactive/dead）
    local kubelet_status
    kubelet_status=$(systemctl is-active kubelet 2>/dev/null || true)
    case "$kubelet_status" in
        inactive|dead|unknown|"")
            log "  ✅ kubelet: 已停止"
            ;;
        active|activating)
            warn "  ❌ kubelet 仍在运行"
            all_clean=false
            ;;
        *)
            log "  ✅ kubelet: $kubelet_status"
            ;;
    esac

    # 残留容器
    if command -v crictl >/dev/null 2>&1 && [[ -n "$CRI_SOCKET" ]]; then
        local remaining_containers remaining_pods
        remaining_containers=$(crictl --runtime-endpoint "$CRI_SOCKET" ps -a 2>/dev/null | tail -n +2 | wc -l || echo 0)
        remaining_pods=$(crictl --runtime-endpoint "$CRI_SOCKET" pods 2>/dev/null | tail -n +2 | wc -l || echo 0)
        if [[ "$remaining_containers" -eq 0 ]]; then
            log "  ✅ 残留容器: 0"
        else
            warn "  ❌ 残留容器: $remaining_containers"
            all_clean=false
        fi
        if [[ "$remaining_pods" -eq 0 ]]; then
            log "  ✅ 残留 Pod:  0"
        else
            warn "  ❌ 残留 Pod:  $remaining_pods"
            all_clean=false
        fi
    fi

    # K8s 配置残留
    if [[ -z "$(ls -A /etc/kubernetes/ 2>/dev/null)" ]]; then
        log "  ✅ /etc/kubernetes: 已清空"
    else
        warn "  ❌ /etc/kubernetes: 有残留文件"
        all_clean=false
    fi

    # CNI 残留（忽略 .kubernetes-cni-keep 等占位文件）
    local cni_residual
    cni_residual=$(find /etc/cni/net.d/ -mindepth 1 -not -name '.*' 2>/dev/null | head -1)
    if [[ -z "$cni_residual" ]]; then
        log "  ✅ CNI 配置: 已清空"
    else
        warn "  ❌ CNI 配置: 有残留"
        all_clean=false
    fi

    echo >&2
    if [[ "$all_clean" == "true" ]]; then
        log "✅ 节点已恢复到初始状态，可以重新 kubeadm join"
    else
        warn "⚠️  部分清理未完成，请检查上述警告"
    fi
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

STEP_NUM=0

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        show_usage
        exit 0
    fi

    check_root
    detect_runtime
    show_node_info

    select_modules "${1:-}"

    [[ "$DRY_RUN" == "1" ]] && warn "DRY-RUN 模式：不会执行任何操作"

    # 计算实际步骤数
    STEP_TOTAL=0
    is_enabled kubelet        && STEP_TOTAL=$((STEP_TOTAL + 1))
    is_enabled kubeadm        && STEP_TOTAL=$((STEP_TOTAL + 1))
    is_enabled containers     && STEP_TOTAL=$((STEP_TOTAL + 1))
    is_enabled images         && STEP_TOTAL=$((STEP_TOTAL + 1))
    is_enabled iptables       && STEP_TOTAL=$((STEP_TOTAL + 1))
    is_enabled ipvs           && STEP_TOTAL=$((STEP_TOTAL + 1))
    is_enabled network        && STEP_TOTAL=$((STEP_TOTAL + 1))
    is_enabled runtime        && STEP_TOTAL=$((STEP_TOTAL + 1))
    is_enabled runtime_config && STEP_TOTAL=$((STEP_TOTAL + 1))
    is_enabled directories    && STEP_TOTAL=$((STEP_TOTAL + 1))
    STEP_TOTAL=$((STEP_TOTAL + 1))  # 验证步骤

    is_enabled kubelet        && stop_kubelet
    is_enabled kubeadm        && run_kubeadm_reset
    is_enabled containers     && cleanup_containers
    is_enabled images         && cleanup_images
    is_enabled iptables       && cleanup_iptables
    is_enabled ipvs           && cleanup_ipvs
    is_enabled network        && cleanup_network_interfaces
    is_enabled runtime        && restart_runtime
    is_enabled runtime_config && reset_runtime_config
    is_enabled directories    && cleanup_directories

    if [[ "$DRY_RUN" != "1" ]]; then
        verify_reset
    fi

    echo >&2
    log "全部完成"
}

main "$@"