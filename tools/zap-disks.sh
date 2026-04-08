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
    #    区分"已挂载/活跃使用"和"未挂载的残留映射"
    #    未挂载的残留不标记为受保护，留给用户选择清理
    #    只追踪到物理磁盘（TYPE=disk），忽略 dm 设备本身

    # 辅助函数：递归获取 dm 设备底层的所有物理磁盘
    get_underlying_physical_disks() {
        local dev_name="$1"
        local slaves_dir="/sys/block/$dev_name/slaves"
        [[ -d "$slaves_dir" ]] || return

        for slave in "$slaves_dir"/*; do
            [[ -e "$slave" ]] || continue
            local slave_name
            slave_name=$(basename "$slave")
            local slave_type
            slave_type=$(lsblk -rno TYPE "/dev/$slave_name" 2>/dev/null | head -1)

            if [[ "$slave_type" == "disk" ]]; then
                # 到达物理磁盘
                echo "/dev/$slave_name"
            else
                # 还是 dm/lvm/part，继续递归
                local parent
                parent=$(lsblk -rno PKNAME "/dev/$slave_name" 2>/dev/null | head -1)
                if [[ -n "$parent" ]]; then
                    local parent_type
                    parent_type=$(lsblk -rno TYPE "/dev/$parent" 2>/dev/null | head -1)
                    if [[ "$parent_type" == "disk" ]]; then
                        echo "/dev/$parent"
                    else
                        get_underlying_physical_disks "$parent"
                    fi
                else
                    get_underlying_physical_disks "$slave_name"
                fi
            fi
        done
    }

    local dm_base
    for dm_base in /sys/block/dm-*; do
        [[ -d "$dm_base/slaves" ]] || continue
        local dm_name
        dm_name=$(basename "$dm_base")
        local dm_dev="/dev/$dm_name"

        # 检查这个 dm 设备是否被挂载或用作 swap
        local dm_in_use=false
        if findmnt -rn -S "$dm_dev" >/dev/null 2>&1; then
            dm_in_use=true
        fi
        if awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | grep -Fxq "$dm_dev"; then
            dm_in_use=true
        fi
        local dm_mapper_name
        dm_mapper_name=$(dmsetup info -c --noheadings -o name "$dm_name" 2>/dev/null || true)
        if [[ -n "$dm_mapper_name" ]]; then
            if findmnt -rn -S "/dev/mapper/$dm_mapper_name" >/dev/null 2>&1; then
                dm_in_use=true
            fi
            if awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | grep -Fxq "/dev/mapper/$dm_mapper_name"; then
                dm_in_use=true
            fi
        fi

        # 只有活跃使用的 dm 才标记其底层物理磁盘为受保护
        if [[ "$dm_in_use" == "true" ]]; then
            while IFS= read -r pdisk; do
                [[ -z "$pdisk" ]] && continue
                if [[ -z "${protected[$pdisk]+_}" ]]; then
                    protected["$pdisk"]="device-mapper 已挂载 ($dm_name)"
                fi
            done < <(get_underlying_physical_disks "$dm_name" | sort -u)
        fi
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

    # 输出（只输出真正的物理磁盘，过滤掉 dm 设备本身）
    for disk in "${!protected[@]}"; do
        local disk_base
        disk_base=$(basename "$disk")
        # dm-* 不是物理磁盘，跳过
        [[ "$disk_base" == dm-* ]] && continue
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
    local dev_name
    dev_name=$(basename "$disk")
    local holders="/sys/block/$dev_name/holders"

    if [[ -d "$holders" ]] && [[ -n "$(ls -A "$holders" 2>/dev/null)" ]]; then
        # 递归检查整个 dm 链是否有活跃使用
        # 递归检查整个设备树是否有活跃使用
        for holder in "$holders"/*; do
            [[ -e "$holder" ]] || continue
            local h_name
            h_name=$(basename "$holder")

            # 检查挂载
            if findmnt -rn -S "/dev/$h_name" >/dev/null 2>&1; then
                die "$disk 有已挂载的 device-mapper 持有者 (/dev/$h_name)，请先 umount"
            fi
            local h_dm_name
            h_dm_name=$(dmsetup info -c --noheadings -o name "$h_name" 2>/dev/null) || true
            if [[ -n "$h_dm_name" ]]; then
                if findmnt -rn -S "/dev/mapper/$h_dm_name" >/dev/null 2>&1; then
                    die "$disk 有已挂载的 device-mapper 持有者 (/dev/mapper/$h_dm_name)，请先 umount"
                fi
                # 检查 open count
                local open_count
                open_count=$(dmsetup info -c --noheadings -o open "$h_name" 2>/dev/null) || true
                if [[ -n "$open_count" && "$open_count" -gt 0 ]]; then
                    die "$disk 的 dm 持有者 $h_dm_name 正在被使用 (open count: $open_count)"
                fi
            fi

            # 递归检查 holder 的 holders
            local hh_dir="/sys/block/$h_name/holders"
            if [[ -d "$hh_dir" ]] && [[ -n "$(ls -A "$hh_dir" 2>/dev/null)" ]]; then
                for hh in "$hh_dir"/*; do
                    [[ -e "$hh" ]] || continue
                    local hh_name
                    hh_name=$(basename "$hh")
                    local hh_dm_name
                    hh_dm_name=$(dmsetup info -c --noheadings -o name "$hh_name" 2>/dev/null) || true
                    if [[ -n "$hh_dm_name" ]]; then
                        local hh_open
                        hh_open=$(dmsetup info -c --noheadings -o open "$hh_name" 2>/dev/null) || true
                        if [[ -n "$hh_open" && "$hh_open" -gt 0 ]]; then
                            die "$disk 的 dm 持有者 $hh_dm_name 正在被使用 (open count: $hh_open)"
                        fi
                        if findmnt -rn -S "/dev/mapper/$hh_dm_name" >/dev/null 2>&1; then
                            die "$disk 有已挂载的 device-mapper 持有者 (/dev/mapper/$hh_dm_name)，请先 umount"
                        fi
                    fi
                done
            fi
        done
    fi
}

# 检查磁盘是否有 dm holders 需要先清理
disk_has_dm_holders() {
    local disk="$1"
    local dev_name
    dev_name=$(basename "$disk")
    local holders="/sys/block/$dev_name/holders"
    [[ -d "$holders" ]] && [[ -n "$(ls -A "$holders" 2>/dev/null)" ]]
}

# 清理磁盘上的 LVM/LUKS/dm 残留映射
# 策略：用 lsblk 获取完整设备树，从叶子节点（最深层）开始逐个拆除
cleanup_disk_dm() {
    local disk="$1"
    local dev_name
    dev_name=$(basename "$disk")

    # 获取该磁盘下所有 dm/lvm/crypt 子设备，按层级深度倒序排列（叶子优先）
    # lsblk 输出格式: NAME TYPE
    local dm_devices
    dm_devices=$(lsblk -rno NAME,TYPE "$disk" 2>/dev/null \
        | awk '$2=="crypt" || $2=="lvm" {print $1}' \
        | tac) || true

    if [[ -n "$dm_devices" ]]; then
        # 1. 从叶子到根逐个关闭 dm 映射
        while IFS= read -r dm_dev; do
            [[ -z "$dm_dev" ]] && continue
            # 获取 mapper 名称
            local dm_mapper_name
            dm_mapper_name=$(cat "/sys/block/$dm_dev/dm/name" 2>/dev/null) || true

            if [[ -z "$dm_mapper_name" ]]; then
                dm_mapper_name=$(dmsetup info -c --noheadings -o name "$dm_dev" 2>/dev/null) || true
            fi

            if [[ -n "$dm_mapper_name" ]]; then
                log "    关闭 dm: $dm_mapper_name"
                if [[ "$DRY_RUN" != "1" ]]; then
                    cryptsetup luksClose "$dm_mapper_name" 2>/dev/null \
                        || dmsetup remove -f "$dm_mapper_name" 2>/dev/null \
                        || true
                fi
            fi
        done <<< "$dm_devices"
    fi

    # 2. 清理 LVM 元数据（VG/PV）
    if command -v pvs >/dev/null 2>&1; then
        local vg_name
        vg_name=$(pvs --noheadings -o vg_name "$disk" 2>/dev/null | awk '{print $1}') || true
        if [[ -n "$vg_name" ]]; then
            log "    清理 LVM: VG=$vg_name"
            if [[ "$DRY_RUN" != "1" ]]; then
                lvremove -f "$vg_name" 2>/dev/null || true
                vgremove -f "$vg_name" 2>/dev/null || true
                pvremove -ff "$disk" 2>/dev/null || true
            fi
        fi
    fi

    # 3. 兜底：如果还有残留 dm，强制清除
    local remaining
    remaining=$(lsblk -rno NAME,TYPE "$disk" 2>/dev/null \
        | awk '$2=="crypt" || $2=="lvm" {print $1}') || true
    if [[ -n "$remaining" ]]; then
        while IFS= read -r dm_dev; do
            [[ -z "$dm_dev" ]] && continue
            local dm_name
            dm_name=$(cat "/sys/block/$dm_dev/dm/name" 2>/dev/null) || true
            if [[ -n "$dm_name" ]]; then
                log "    强制清理残留: $dm_name"
                dmsetup remove -f "$dm_name" 2>/dev/null || true
            fi
        done <<< "$remaining"
    fi

    # 4. 等待内核释放
    if [[ "$DRY_RUN" != "1" ]]; then
        udevadm settle --timeout=5 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# 交互式磁盘选择
# ---------------------------------------------------------------------------

# 列出所有可清理的磁盘（排除受保护磁盘）
get_available_disks() {

    # 检查单个设备是否正在被使用（不递归）
    is_dev_in_use() {
        local dev_name="$1"
        local dev_path="/dev/$dev_name"

        # 1. 挂载检查
        if findmnt -rn -S "$dev_path" >/dev/null 2>&1; then
            return 0
        fi

        # 2. /dev/mapper/ 路径挂载检查（dm 设备）
        if [[ "$dev_name" == dm-* ]]; then
            local mapper_name
            mapper_name=$(dmsetup info -c --noheadings -o name "$dev_name" 2>/dev/null) || true
            if [[ -n "$mapper_name" ]]; then
                if findmnt -rn -S "/dev/mapper/$mapper_name" >/dev/null 2>&1; then
                    return 0
                fi
            fi
        fi

        # 3. swap 检查
        if awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | grep -Fq "$dev_path"; then
            return 0
        fi

        # 4. dm open count（进程直接用裸设备的场景，如 Ceph OSD BlueStore）
        if [[ "$dev_name" == dm-* ]]; then
            local open_count
            open_count=$(dmsetup info -c --noheadings -o open "$dev_name" 2>/dev/null) || true
            if [[ -n "$open_count" && "$open_count" -gt 0 ]]; then
                return 0
            fi
        fi

        # 5. fuser 检查（进程直接打开裸设备但没有 dm 层的场景）
        if command -v fuser >/dev/null 2>&1; then
            if fuser "$dev_path" >/dev/null 2>&1; then
                return 0
            fi
        fi

        return 1
    }

    # 递归检查一个磁盘及其所有下游设备是否正在被使用
    # 覆盖场景：
    #   - 磁盘自身被直接使用（挂载/swap/fuser）
    #   - dm/LVM/md holders 链（多层嵌套）
    #   - 分区被使用（GPT 分区表存在时检查每个分区）
    is_device_tree_in_use() {
        local dev_name="$1"

        # 检查设备自身
        if is_dev_in_use "$dev_name"; then
            return 0
        fi

        # 递归检查所有 holders（dm/LVM/md）
        local h_dir="/sys/block/$dev_name/holders"
        if [[ -d "$h_dir" ]]; then
            for h in "$h_dir"/*; do
                [[ -e "$h" ]] || continue
                if is_device_tree_in_use "$(basename "$h")"; then
                    return 0
                fi
            done
        fi

        # 检查分区（磁盘有分区表时，每个分区也要检查）
        local part
        for part in /sys/block/"$dev_name"/"${dev_name}"*; do
            [[ -d "$part" ]] || continue
            local part_name
            part_name=$(basename "$part")
            # 检查分区自身
            if is_dev_in_use "$part_name"; then
                return 0
            fi
            # 检查分区的 holders（分区上的 LVM/dm）
            local ph_dir="$part/holders"
            if [[ -d "$ph_dir" ]]; then
                for ph in "$ph_dir"/*; do
                    [[ -e "$ph" ]] || continue
                    if is_device_tree_in_use "$(basename "$ph")"; then
                        return 0
                    fi
                done
            fi
        done

        return 1
    }
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

        # 跳过虚拟/无用设备（nbd、loop、ram、zram）
        case "$dev_name" in
            nbd*|loop*|ram*|zram*) continue ;;
        esac

        # 跳过容量为 0 的设备
        local dev_size
        dev_size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        [[ "$dev_size" -eq 0 ]] && continue

        # 跳过有活跃挂载的 holders（递归检查整个 dm 链）
        # 有未挂载的 dm holders 仍然列入可选（LVM/LUKS 残留）
        local holders="/sys/block/$dev_name/holders"
        if [[ -d "$holders" ]] && [[ -n "$(ls -A "$holders" 2>/dev/null)" ]]; then
            if is_device_tree_in_use "$dev_name"; then
                continue
            fi
            # 未挂载的 dm holders — 允许列入可选列表
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
        local dev_name_short
        dev_name_short=$(basename "$dev")
        local has_holders=false
        if [[ -d "/sys/block/$dev_name_short/holders" ]] && \
           [[ -n "$(ls -A "/sys/block/$dev_name_short/holders" 2>/dev/null)" ]]; then
            has_holders=true
        fi

        if [[ "$has_holders" == "true" ]]; then
            # 有 dm holders 但未挂载（残留）
            local holder_types=""
            if command -v pvs >/dev/null 2>&1 && pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' | grep -Fxq "$dev"; then
                holder_types="LVM"
            fi
            if blkid "$dev" 2>/dev/null | grep -q 'crypto_LUKS'; then
                holder_types="${holder_types:+$holder_types+}LUKS"
            fi
            note="${YELLOW}${holder_types:-dm} 残留（自动清理）${NC}"
        elif blkid "$dev" 2>/dev/null | grep -qi 'ceph'; then
            note="BlueStore 签名"
        elif blkid "$dev" >/dev/null 2>&1; then
            note="有文件系统签名"
        else
            note="空盘"
        fi

        printf "  %-4s %-12s %-10s %-8s %b\n" \
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
    local step_num="${2:-}"
    local step_total="${3:-}"
    local disk_size block_size off

    disk_size=$(blockdev --getsize64 "$disk")
    block_size=$(blockdev --getss "$disk")

    # BlueStore 使用 max(device_sector_size, 4096) 作为对齐单位
    if [[ "$block_size" -lt "$LABEL_ZAP_SIZE" ]]; then
        block_size="$LABEL_ZAP_SIZE"
    fi

    if [[ -n "$step_num" && -n "$step_total" ]]; then
        log "  [${step_num}/${step_total}] 清除 BlueStore label 副本（5个偏移位置）"
    else
        log "  清除 BlueStore label 副本（5个偏移位置）"
    fi

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

    # 判断是否需要先清理 dm 映射
    local has_dm=false
    local total_steps=5
    if disk_has_dm_holders "$disk"; then
        has_dm=true
        total_steps=6
    fi

    local step=0

    # 步骤 0（可选）: 清理 LVM/LUKS/dm 残留
    if [[ "$has_dm" == "true" ]]; then
        step=$((step + 1))
        log "  [${step}/${total_steps}] 清理 LVM/dm 残留映射"
        cleanup_disk_dm "$disk"
    fi

    # 步骤 1: 清除分区表
    step=$((step + 1))
    log "  [${step}/${total_steps}] 清除分区表 (sgdisk --zap-all)"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "  [DRY-RUN] sgdisk --zap-all $disk"
    else
        sgdisk --zap-all "$disk" >/dev/null 2>&1 || true
    fi

    # 步骤 2: 清零磁盘头部
    step=$((step + 1))
    log "  [${step}/${total_steps}] 清零磁盘头部 ${HEAD_ZAP_MIB}MiB"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "  [DRY-RUN] dd if=/dev/zero of=$disk bs=1M count=$HEAD_ZAP_MIB"
    else
        dd if=/dev/zero of="$disk" \
            bs=1M count="$HEAD_ZAP_MIB" \
            oflag=direct,dsync >/dev/null 2>&1
    fi

    # 步骤 3: 清除文件系统签名
    step=$((step + 1))
    log "  [${step}/${total_steps}] 清除文件系统签名 (wipefs)"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "  [DRY-RUN] wipefs -af $disk"
    else
        wipefs -af "$disk" >/dev/null 2>&1 || true
    fi

    # 步骤 4: 清除 BlueStore label
    step=$((step + 1))
    wipe_bluestore_labels "$disk" "$step" "$total_steps"

    # 步骤 5: 通知内核
    step=$((step + 1))
    log "  [${step}/${total_steps}] 通知内核重新读取分区表 (partprobe)"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "  [DRY-RUN] partprobe $disk"
    else
        partprobe "$disk" >/dev/null 2>&1 || true
    fi

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