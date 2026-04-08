#!/usr/bin/env bash
# =============================================================================
# zap-disks.sh — 磁盘清理脚本（Rook-Ceph OSD 重用前准备）
#
# 等价替代 ceph-bluestore-tool zap-device，无需安装 ceph-osd 包。
# 兼容 CRI-O / containerd / 任意 CRI 运行时的 Kubernetes 节点。
#
# 依赖:
#   - gdisk (sgdisk)    — apt install gdisk
#   - parted (partprobe) — apt install parted
#   - util-linux (wipefs, blkid, findmnt, blockdev) — 系统自带
#   - coreutils (dd)     — 系统自带
#
# 用法:
#   # 交互式选择磁盘（推荐）
#   sudo bash zap-disks.sh
#
#   # 指定磁盘（跳过交互，无需确认）
#   sudo bash zap-disks.sh /dev/vdb /dev/vdc
#
#   # 仅检查（dry-run），不执行任何写操作
#   DRY_RUN=1 sudo bash zap-disks.sh
#
# BlueStore label 偏移量来源:
#   ceph/src/os/bluestore/BlueStore.cc -> bdev_label_positions
#   文档: https://docs.ceph.com/en/latest/man/8/ceph-bluestore-tool/
#   主设备 label 副本位于: 0, 1GiB, 10GiB, 100GiB, 1000GiB
#   DB/WAL 设备仅在偏移 0 处有一个 label
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------

# BlueStore label 副本的字节偏移量
BLUESTORE_LABEL_OFFSETS=(
    0              # 0 GiB
    1073741824     # 1 GiB
    10737418240    # 10 GiB
    107374182400   # 100 GiB
    1073741824000  # 1000 GiB
)

# 每个 label 位置清零的大小（字节），4096 足够覆盖 label 结构
LABEL_ZAP_SIZE=4096

# 磁盘头部清零大小（MiB），覆盖分区表/FS header/LVM/LUKS header
HEAD_ZAP_MIB=100

# Dry-run 模式：设置 DRY_RUN=1 仅打印操作不执行
DRY_RUN="${DRY_RUN:-0}"

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------

readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

log()  { echo -e "[$(date -u +'%F %T')] ${GREEN}INFO${NC}  $*" >&2; }
warn() { echo -e "[$(date -u +'%F %T')] ${YELLOW}WARN${NC}  $*" >&2; }
err()  { echo -e "[$(date -u +'%F %T')] ${RED}ERROR${NC} $*" >&2; }
die()  { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------

check_root() {
    [[ $EUID -eq 0 ]] || die "必须以 root 身份运行"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1（请安装对应的包）"
}

check_dependencies_soft() {
    # 交互阶段只需要基础系统命令（无需 sgdisk/partprobe）
    require_cmd dd
    require_cmd blockdev
    require_cmd blkid
    require_cmd findmnt
    require_cmd lsblk
}

check_dependencies() {
    require_cmd sgdisk
    require_cmd dd
    require_cmd wipefs
    require_cmd partprobe
    require_cmd blockdev
    require_cmd blkid
    require_cmd findmnt
}

install_packages() {
    local need_sgdisk=0 need_parted=0
    command -v sgdisk    >/dev/null 2>&1 || need_sgdisk=1
    command -v partprobe >/dev/null 2>&1 || need_parted=1

    [[ "$need_sgdisk" -eq 0 && "$need_parted" -eq 0 ]] && return 0

    local pkgs=()
    [[ "$need_sgdisk" -eq 1 ]] && pkgs+=(gdisk)
    [[ "$need_parted" -eq 1 ]] && pkgs+=(parted)

    log "安装缺失的软件包: ${pkgs[*]}"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY-RUN] 安装 ${pkgs[*]}"
        return 0
    fi

    if command -v apt >/dev/null 2>&1; then
        apt update -qq && apt install -y -qq "${pkgs[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "${pkgs[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "${pkgs[@]}"
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y "${pkgs[@]}"
    else
        die "无法自动安装依赖，请手动安装: ${pkgs[*]}"
    fi
}

# ---------------------------------------------------------------------------
# 安全检查
# ---------------------------------------------------------------------------

check_block_device() {
    local disk="$1"
    [[ -b "$disk" ]] || die "不是块设备: $disk"
}

# 获取块设备所属的顶层磁盘，如 /dev/vda1 -> /dev/vda
get_parent_disk() {
    local dev="$1"
    local base parent
    base=$(basename "$dev")
    parent=$(lsblk -rno PKNAME "/dev/$base" 2>/dev/null | head -1)
    if [[ -n "$parent" ]]; then
        echo "/dev/$parent"
    else
        echo "/dev/$base"
    fi
}

# 收集当前系统所有受保护的磁盘
# 返回格式: 每行 "磁盘路径|原因"
get_protected_disks() {
    local -A protected=()

    # 1. 根文件系统所在磁盘
    local root_dev
    root_dev=$(findmnt -rno SOURCE / 2>/dev/null | head -1)
    if [[ -n "$root_dev" ]]; then
        if [[ "$root_dev" == /dev/mapper/* ]] || [[ "$root_dev" == /dev/dm-* ]]; then
            # LVM/dm 设备：解析到底层物理设备
            local dm_real
            dm_real=$(basename "$(readlink -f "$root_dev")" 2>/dev/null)
            if [[ -d "/sys/block/$dm_real/slaves" ]]; then
                for slave in /sys/block/"$dm_real"/slaves/*; do
                    [[ -e "$slave" ]] || continue
                    local pdisk
                    pdisk=$(get_parent_disk "$(basename "$slave")")
                    protected["$pdisk"]="rootfs (via $root_dev)"
                done
            fi
        else
            local pdisk
            pdisk=$(get_parent_disk "$root_dev")
            protected["$pdisk"]="rootfs ($root_dev)"
        fi
    fi

    # 2. 所有当前挂载的文件系统所在磁盘
    while IFS= read -r mount_src; do
        [[ -b "$mount_src" ]] || continue
        local pdisk
        pdisk=$(get_parent_disk "$mount_src")
        if [[ -z "${protected[$pdisk]+_}" ]]; then
            protected["$pdisk"]="已挂载 ($mount_src)"
        fi
    done < <(findmnt -rno SOURCE 2>/dev/null | sort -u)

    # 3. 活跃的 swap 设备
    while IFS= read -r swap_dev; do
        [[ -b "$swap_dev" ]] || continue
        local pdisk
        pdisk=$(get_parent_disk "$swap_dev")
        if [[ -z "${protected[$pdisk]+_}" ]]; then
            protected["$pdisk"]="swap ($swap_dev)"
        fi
    done < <(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null)

    # 4. device-mapper 活跃目标（LVM/LUKS/multipath）
    local dm_base
    for dm_base in /sys/block/dm-*; do
        [[ -d "$dm_base/slaves" ]] || continue
        for slave in "$dm_base"/slaves/*; do
            [[ -e "$slave" ]] || continue
            local pdisk
            pdisk=$(get_parent_disk "$(basename "$slave")")
            if [[ -z "${protected[$pdisk]+_}" ]]; then
                protected["$pdisk"]="device-mapper ($(basename "$dm_base"))"
            fi
        done
    done

    # 5. 活跃的 Ceph OSD（cephadm/手动部署场景）
    if command -v ceph-volume >/dev/null 2>&1; then
        while IFS= read -r osd_dev; do
            [[ -b "$osd_dev" ]] || continue
            local pdisk
            pdisk=$(get_parent_disk "$osd_dev")
            if [[ -z "${protected[$pdisk]+_}" ]]; then
                protected["$pdisk"]="活跃 Ceph OSD ($osd_dev)"
            fi
        done < <(ceph-volume lvm list --format json 2>/dev/null \
            | grep -oP '"path"\s*:\s*"\K[^"]+' 2>/dev/null)
    fi

    # 输出
    for disk in "${!protected[@]}"; do
        echo "${disk}|${protected[$disk]}"
    done
}

# 检查目标磁盘是否受保护
check_not_protected() {
    local disk="$1"
    local disk_real
    disk_real=$(readlink -f "$disk")

    while IFS='|' read -r pdisk preason; do
        [[ -z "$pdisk" ]] && continue
        if [[ "$disk_real" == "$(readlink -f "$pdisk")" ]]; then
            die "拒绝清理 $disk: 受保护磁盘 — $preason"
        fi
    done <<< "$PROTECTED_DISKS"
}

check_not_mounted() {
    local disk="$1"
    if findmnt -rn -S "$disk" >/dev/null 2>&1; then
        die "设备已挂载: $disk（请先 umount）"
    fi
    # 检查分区是否挂载
    for part in "${disk}"*; do
        [[ "$part" == "$disk" ]] && continue
        if findmnt -rn -S "$part" >/dev/null 2>&1; then
            die "分区已挂载: $part（请先 umount）"
        fi
    done
}

check_not_in_use() {
    local disk="$1"
    local holders="/sys/block/$(basename "$disk")/holders"
    if [[ -d "$holders" ]] && [[ -n "$(ls -A "$holders" 2>/dev/null)" ]]; then
        die "$disk 有活跃的 device-mapper 持有者: $(ls "$holders")（LVM/LUKS/multipath，请先清理）"
    fi
}

# ---------------------------------------------------------------------------
# 交互式磁盘选择
# ---------------------------------------------------------------------------

# 列出所有可清理的磁盘（排除受保护磁盘）
get_available_disks() {
    local -a available=()
    local -A protected_set=()

    # 构建受保护磁盘集合
    while IFS='|' read -r pdisk _; do
        [[ -z "$pdisk" ]] && continue
        protected_set["$(readlink -f "$pdisk")"]=1
    done <<< "$PROTECTED_DISKS"

    # 遍历所有块设备（只取顶层磁盘，排除分区/loop/dm）
    while IFS= read -r dev_name; do
        local dev="/dev/$dev_name"
        [[ -b "$dev" ]] || continue

        local dev_real
        dev_real=$(readlink -f "$dev")

        # 跳过受保护磁盘
        [[ -n "${protected_set[$dev_real]+_}" ]] && continue

        # 跳过有活跃 holders 的磁盘
        local holders="/sys/block/$dev_name/holders"
        if [[ -d "$holders" ]] && [[ -n "$(ls -A "$holders" 2>/dev/null)" ]]; then
            continue
        fi

        available+=("$dev")
    done < <(lsblk -rno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')

    printf '%s\n' "${available[@]}"
}

# 交互式选择磁盘
# 注意: 所有交互输出走 stderr，只有最终选中的磁盘路径走 stdout
interactive_select_disks() {
    local -a available=()
    local -a selected=()

    # 读取可用磁盘列表
    while IFS= read -r dev; do
        [[ -n "$dev" ]] && available+=("$dev")
    done < <(get_available_disks)

    if [[ ${#available[@]} -eq 0 ]]; then
        die "没有找到可清理的磁盘（所有磁盘均被保护或正在使用）"
    fi

    echo >&2
    log "可清理的磁盘:"
    echo >&2
    printf "  %-4s %-12s %-10s %-8s %s\n" "编号" "设备" "容量" "扇区" "备注" >&2
    printf "  %-4s %-12s %-10s %-8s %s\n" "----" "--------" "------" "----" "----" >&2

    local i
    for i in "${!available[@]}"; do
        local dev="${available[$i]}"
        local size_bytes size_human sector_size note=""

        size_bytes=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        size_human=$(numfmt --to=iec-i --suffix=B "$size_bytes" 2>/dev/null || echo "${size_bytes}B")
        sector_size=$(blockdev --getss "$dev" 2>/dev/null || echo "?")

        # 检查磁盘当前状态
        if blkid "$dev" 2>/dev/null | grep -qi 'ceph'; then
            note="BlueStore 签名"
        elif blkid "$dev" >/dev/null 2>&1; then
            note="有文件系统签名"
        else
            note="空盘"
        fi

        printf "  %-4s %-12s %-10s %-8s %s\n" \
            "$((i + 1))" "$dev" "$size_human" "${sector_size}B" "$note" >&2
    done

    echo >&2
    printf "  [A]  全选\n" >&2
    echo >&2

    # 根据检测到的磁盘数量生成操作提示
    local hint=""
    if [[ ${#available[@]} -eq 1 ]]; then
        hint="  ${GREEN}选择:${NC} 1    ${GREEN}退出:${NC} q"
    elif [[ ${#available[@]} -eq 2 ]]; then
        hint="  ${GREEN}单选:${NC} 1    ${GREEN}多选:${NC} 1,2    ${GREEN}全选:${NC} A    ${GREEN}退出:${NC} q"
    else
        hint="  ${GREEN}单选:${NC} 1    ${GREEN}多选:${NC} 1,2,3    ${GREEN}全选:${NC} A    ${GREEN}退出:${NC} q"
    fi

    printf "${hint}\n" >&2
    echo >&2

    local input
    read -rep "请输入要清理的磁盘编号: " input </dev/tty

    # 退出
    if [[ "$input" == "q" || "$input" == "Q" ]]; then
        log "用户取消操作"
        exit 0
    fi

    # 全选
    if [[ "$input" == "a" || "$input" == "A" ]]; then
        selected=("${available[@]}")
    else
        # 解析编号（支持空格和逗号分隔）
        input="${input//,/ }"
        for num in $input; do
            # 验证是数字
            if ! [[ "$num" =~ ^[0-9]+$ ]]; then
                die "无效的编号: $num"
            fi
            local idx=$((num - 1))
            if [[ $idx -lt 0 || $idx -ge ${#available[@]} ]]; then
                die "编号超出范围: $num（有效范围: 1-${#available[@]}）"
            fi
            selected+=("${available[$idx]}")
        done
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        die "未选择任何磁盘"
    fi

    # 二次确认
    echo >&2
    warn "即将清理以下磁盘（数据不可恢复）:"
    for dev in "${selected[@]}"; do
        local size_human
        size_human=$(numfmt --to=iec-i --suffix=B "$(blockdev --getsize64 "$dev")" 2>/dev/null || echo "?")
        warn "  $dev ($size_human)"
    done
    echo >&2

    local confirm
    read -rep "确认清理？输入 YES 继续: " confirm </dev/tty
    if [[ "$confirm" != "YES" ]]; then
        log "用户取消操作"
        exit 0
    fi

    # 只有这里走 stdout，供 main 捕获
    printf '%s\n' "${selected[@]}"
}

# ---------------------------------------------------------------------------
# 信息检查（非阻塞，仅提示）
# ---------------------------------------------------------------------------

show_residual_hints() {
    local disk="$1"

    # LUKS 残留检查
    if blkid "$disk" 2>/dev/null | grep -q 'TYPE="crypto_LUKS"'; then
        warn "$disk 检测到 LUKS 签名（如需完整清理: cryptsetup luksErase $disk）"
    fi

    # LVM PV 残留检查
    if command -v pvs >/dev/null 2>&1; then
        if pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' | grep -Fxq "$disk"; then
            warn "$disk 注册为 LVM PV（如需完整清理: pvremove -ff $disk）"
        fi
    fi

    # 检查是否有已知的 BlueStore 签名
    if blkid "$disk" 2>/dev/null | grep -q 'ceph'; then
        warn "$disk blkid 输出包含 ceph 相关签名"
    fi
}

show_disk_info() {
    local disk="$1"
    local size_bytes size_human

    size_bytes=$(blockdev --getsize64 "$disk")
    size_human=$(numfmt --to=iec-i --suffix=B "$size_bytes" 2>/dev/null || echo "${size_bytes} bytes")

    log "$disk: 容量 $size_human, 扇区大小 $(blockdev --getss "$disk") 字节"
}

# ---------------------------------------------------------------------------
# 核心清理操作
# ---------------------------------------------------------------------------

# 清除分区表
wipe_partition_table() {
    local disk="$1"
    log "  [1/5] 清除分区表 (sgdisk --zap-all)"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "  [DRY-RUN] sgdisk --zap-all $disk"
    else
        sgdisk --zap-all "$disk" >/dev/null 2>&1 || true
    fi
}

# 清零磁盘头部
wipe_disk_head() {
    local disk="$1"
    log "  [2/5] 清零磁盘头部 ${HEAD_ZAP_MIB}MiB"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "  [DRY-RUN] dd if=/dev/zero of=$disk bs=1M count=$HEAD_ZAP_MIB"
    else
        dd if=/dev/zero of="$disk" \
            bs=1M count="$HEAD_ZAP_MIB" \
            oflag=direct,dsync >/dev/null 2>&1
    fi
}

# 清除文件系统签名
wipe_fs_signatures() {
    local disk="$1"
    log "  [3/5] 清除文件系统签名 (wipefs)"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "  [DRY-RUN] wipefs -af $disk"
    else
        wipefs -af "$disk" >/dev/null 2>&1 || true
    fi
}

# 清除 BlueStore label（等价 ceph-bluestore-tool zap-device）
wipe_bluestore_labels() {
    local disk="$1"
    local disk_size block_size off

    disk_size=$(blockdev --getsize64 "$disk")
    block_size=$(blockdev --getss "$disk")

    # BlueStore 使用 max(device_sector_size, 4096) 作为对齐单位
    if [[ "$block_size" -lt "$LABEL_ZAP_SIZE" ]]; then
        block_size="$LABEL_ZAP_SIZE"
    fi

    log "  [4/5] 清除 BlueStore label 副本（5个偏移位置）"

    for off in "${BLUESTORE_LABEL_OFFSETS[@]}"; do
        if [[ "$off" -lt "$disk_size" ]]; then
            local off_human
            off_human=$(numfmt --to=iec-i --suffix=B "$off" 2>/dev/null || echo "${off}")
            if [[ "$DRY_RUN" == "1" ]]; then
                log "  [DRY-RUN] 清零偏移 $off_human 处 label"
            else
                dd if=/dev/zero of="$disk" \
                    bs="$block_size" count=1 \
                    seek=$((off / block_size)) \
                    conv=notrunc oflag=direct,dsync \
                    >/dev/null 2>&1
            fi
        fi
    done
}

# 通知内核重新读取分区表
reload_partition_table() {
    local disk="$1"
    log "  [5/5] 通知内核重新读取分区表 (partprobe)"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "  [DRY-RUN] partprobe $disk"
    else
        partprobe "$disk" >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# 清理后验证
# ---------------------------------------------------------------------------

verify_clean() {
    local disk="$1"
    local clean=true

    # 验证 blkid 无输出
    if blkid "$disk" >/dev/null 2>&1; then
        warn "$disk 清理后 blkid 仍检测到签名: $(blkid "$disk" 2>/dev/null)"
        clean=false
    fi

    # 验证无分区
    local part_count
    part_count=$(lsblk -rn -o NAME "$disk" 2>/dev/null | wc -l)
    if [[ "$part_count" -gt 1 ]]; then
        warn "$disk 清理后仍有 $((part_count - 1)) 个分区"
        clean=false
    fi

    if [[ "$clean" == "true" ]]; then
        log "$disk 验证通过: 磁盘干净"
    fi
}

# ---------------------------------------------------------------------------
# 单盘清理流程
# ---------------------------------------------------------------------------

wipe_disk() {
    local disk="$1"

    check_block_device "$disk"
    check_not_protected "$disk"
    check_not_mounted "$disk"
    check_not_in_use "$disk"

    show_disk_info "$disk"
    show_residual_hints "$disk"

    wipe_partition_table "$disk"
    wipe_disk_head "$disk"
    wipe_fs_signatures "$disk"
    wipe_bluestore_labels "$disk"
    reload_partition_table "$disk"

    if [[ "$DRY_RUN" != "1" ]]; then
        verify_clean "$disk"
    fi

    log "$disk 清理完成"
    echo
}

# ---------------------------------------------------------------------------
# 用法帮助
# ---------------------------------------------------------------------------

show_usage() {
    cat >&2 <<EOF
用法: $(basename "$0") [选项] [设备...]

清理磁盘以供 Rook-Ceph OSD 重新使用。
等价替代 ceph-bluestore-tool zap-device，无需安装 ceph-osd 包。

选项:
  -h, --help    显示此帮助信息

参数:
  设备...       要清理的块设备路径（如 /dev/vdb /dev/vdc）

示例:
  $(basename "$0")                        交互式选择磁盘
  $(basename "$0") /dev/vdb               清理单块磁盘
  $(basename "$0") /dev/vdb /dev/vdc      清理多块磁盘
  DRY_RUN=1 $(basename "$0")              仅预览，不执行写操作

说明:
  - 不带参数运行时进入交互式模式，列出可清理的磁盘供选择
  - 自动检测并保护系统盘、swap、LVM/LUKS/活跃 OSD 使用的磁盘
  - 清理步骤: 分区表 → 头部100MiB → 文件系统签名 → BlueStore label → partprobe
EOF
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

main() {
    # 帮助信息
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        show_usage
        exit 0
    fi

    local disks=("$@")

    check_root
    check_dependencies_soft

    # 一次性计算受保护磁盘列表（系统盘/swap/dm/OSD）
    PROTECTED_DISKS=$(get_protected_disks)

    # 显示受保护磁盘
    if [[ -n "$PROTECTED_DISKS" ]]; then
        log "受保护磁盘（以下磁盘不会被清理）:"
        while IFS='|' read -r pdisk preason; do
            [[ -z "$pdisk" ]] && continue
            log "  $pdisk — $preason"
        done <<< "$PROTECTED_DISKS"
    fi

    # 无参数时进入交互式选择
    if [[ ${#disks[@]} -eq 0 ]]; then
        local selection
        selection=$(interactive_select_disks)
        local rc=$?
        if [[ $rc -ne 0 ]] || [[ -z "$selection" ]]; then
            exit 0
        fi
        while IFS= read -r dev; do
            [[ -n "$dev" ]] && disks+=("$dev")
        done <<< "$selection"
    fi

    if [[ ${#disks[@]} -eq 0 ]]; then
        log "未选择任何磁盘，退出"
        exit 0
    fi

    # 用户确认后静默安装依赖
    install_packages
    check_dependencies

    log "开始磁盘清理（共 ${#disks[@]} 块磁盘）"
    [[ "$DRY_RUN" == "1" ]] && warn "DRY-RUN 模式：不会执行任何写操作"
    echo

    for disk in "${disks[@]}"; do
        wipe_disk "$disk"
    done

    log "全部清理完成"
}

main "$@"