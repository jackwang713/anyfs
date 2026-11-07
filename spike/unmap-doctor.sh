#!/bin/bash
# unmap-doctor.sh — USB 存储设备 UNMAP/TRIM 支持能力三级诊断
#
# 三级协议:
#   第 1 级  固件宣告   — VPD 页(纯只读): 它"声称"行不行
#   第 2 级  内核政策   — sysfs(纯只读): Linux "给不给"它用
#   第 3 级  执行验证   — 图案读回法(--live 开启): UNMAP 到底到没到 NAND
#
# 安全性:
#   默认只做第 1+2 级, 全程只读。
#   第 3 级(--live)会向设备上已挂载文件系统写入一个 512MB 图案文件并删除,
#   然后仅对该文件原先占用的 1MB 空闲簇发一次 UNMAP 并读回验证,
#   不触碰任何现存数据。执行前需确认。
#
# 用法:
#   sudo ./unmap-doctor.sh                  # 交互选择 USB 设备 (第 1+2 级)
#   sudo ./unmap-doctor.sh /dev/sdX         # 指定设备 (第 1+2 级)
#   sudo ./unmap-doctor.sh /dev/sdX --live  # 追加第 3 级执行验证
#   sudo ./unmap-doctor.sh /dev/sdX --fix   # 解封内核政策(provisioning_mode=unmap)
#   其他: --yes 跳过确认, --json 机器可读输出, --size MB 图案大小(默认 512)

set -u
export LC_ALL=C

DEV="" DO_LIVE=0 DO_FIX=0 ASSUME_YES=0 JSON=0 PATTERN_SIZE_MB=512
CHUNK=$((1024*1024))          # 验证块 1MB
PATTERN_BYTE=0x5A             # 验证图案

# ---------- 输出 ----------
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_0=$'\033[0m'
info()  { [ $JSON -eq 0 ] && echo "$*"; }
head_() { [ $JSON -eq 0 ] && echo -e "\n${C_B}== $* ==${C_0}"; }
ok()    { [ $JSON -eq 0 ] && echo -e "  ${C_G}✅ $*${C_0}"; }
warn()  { [ $JSON -eq 0 ] && echo -e "  ${C_Y}⚠️  $*${C_0}"; }
bad()   { [ $JSON -eq 0 ] && echo -e "  ${C_R}❌ $*${C_0}"; }
ask()   { [ $JSON -eq 0 ] && echo -e "  ${C_B}❓ $*${C_0}"; }
die()   { echo "错误: $*" >&2; exit 1; }
KV=(); kv() { KV+=("$1=$2"); }

usage() { sed -n '2,30p' "$0"; exit 0; }

# ---------- 参数 ----------
while [ $# -gt 0 ]; do
    case "$1" in
        /dev/*)   DEV="$1" ;;
        --live)   DO_LIVE=1 ;;
        --fix)    DO_FIX=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --json)   JSON=1 ;;
        --size)   shift; PATTERN_SIZE_MB="${1:?--size 需要参数}" ;;
        -h|--help) usage ;;
        *)        die "未知参数: $1 (用 --help 查看用法)" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "需要 root 运行 (SG_IO/sysfs 访问), 请用 sudo"

# ---------- 依赖 ----------
have() { command -v "$1" >/dev/null 2>&1; }
for c in lsblk udevadm; do have "$c" || die "缺少命令: $c"; done
MISSING_SG=0
for c in sg_vpd sg_inq sg_unmap; do have "$c" || MISSING_SG=1; done
if [ $MISSING_SG -eq 1 ]; then
    warn "缺少 sg3_utils (sg_vpd/sg_inq/sg_unmap), 第 1/3 级将受限"
    warn "安装: apt install sg3-utils"
fi

# ---------- 设备选择 ----------
pick_device() {
    head_ "选择 USB 设备"
    lsblk -dp -o NAME,SIZE,MODEL,TRAN | awk 'NR==1 || $4=="usb"'
    echo
    printf "输入设备路径 (如 /dev/sdb): "
    read -r DEV
}
[ -z "$DEV" ] && pick_device
[ -b "$DEV" ] || die "$DEV 不是块设备"
DEVNODE=$(basename "$DEV")

# 拒绝误伤系统盘 (除非设备本身就是 USB)
TRAN=$(lsblk -dno TRAN "$DEV" 2>/dev/null || true)
if [ "$TRAN" != "usb" ] && [ "$TRAN" != "" ]; then
    warn "$DEV 的传输类型是 '$TRAN' 而非 usb"
    [ $ASSUME_YES -eq 1 ] || { printf "确认继续? [y/N] "; read -r a; [ "$a" = "y" ] || exit 1; }
fi

# ---------- 工具函数 ----------
usb_ids() {  # 输出 "VID PID"
    udevadm info --query=property --name="$DEV" 2>/dev/null \
        | awk -F= '/^ID_VENDOR_ID=/{v=$2} /^ID_MODEL_ID=/{m=$2} END{print v, m}'
}
usb_driver() {
    udevadm info --query=property --name="$DEV" 2>/dev/null \
        | awk -F= '/^ID_USB_DRIVER=/{print $2}'
}
sysq() { cat "/sys/block/$DEVNODE/queue/$1" 2>/dev/null || echo "?"; }
sd_attr() { cat /sys/block/"$DEVNODE"/device/scsi_disk/*/"$1" 2>/dev/null || echo "?"; }

# ---------- 报告数据收集 ----------
R_TRANSPORT="" R_VIDPID="" R_FW="" R_LBPU="" R_LBPWS="" R_LBPWS10=""
R_PROVTYPE="" R_MAXDESC="" R_DMAX="" R_DMAXHW="" R_DGRAN="" R_DZERO=""
R_PROV="" R_THIN="" R_VERDICT="" R_DETAIL=""

# ---------- 第 0 级: 设备识别 ----------
head_ "第 0 级 · 设备识别"
MODEL=$(lsblk -dno MODEL "$DEV" 2>/dev/null | sed 's/  */ /g')
SERIAL=$(lsblk -dno SERIAL "$DEV" 2>/dev/null)
SIZE=$(lsblk -dno SIZE "$DEV")
read -r VID PID <<<"$(usb_ids)"
DRIVER=$(usb_driver)
R_TRANSPORT="$DRIVER"; R_VIDPID="$VID:$PID"
info "  设备: $DEV  型号: ${MODEL:-未知}  序列号: ${SERIAL:-未知}  容量: $SIZE"
info "  USB ID: ${VID:-?}:${PID:-?}  驱动: ${DRIVER:-未知}"
kv model "$MODEL"; kv vid_pid "$R_VIDPID"; kv transport "$DRIVER"

if [ "$DRIVER" = "usb-storage" ]; then
    bad "传输协议是 BOT (usb-storage) —— 协议层没有 UNMAP 命令, 后面不用再测"
    R_VERDICT="NO_TRANSPORT"; R_DETAIL="BOT 协议不支持 UNMAP"
    kv verdict "$R_VERDICT"; kv detail "$R_DETAIL"
    [ $JSON -eq 1 ] && printf '%s\n' "${KV[@]}"
    exit 2
elif [ "$DRIVER" = "uas" ]; then
    ok "UASP 传输 (协议支持 UNMAP)"
else
    warn "传输驱动识别为 '${DRIVER:-未知}', 继续探测"
fi

if [ $MISSING_SG -eq 0 ]; then
    INQ=$(sg_inq "$DEV" 2>/dev/null | grep -E 'vendor|product|revision' | tr -s ' ' | tr '\n' ' ')
    R_FW=$(sg_inq "$DEV" 2>/dev/null | awk -F: '/revision/{gsub(/ /,"",$2); print $2}')
    info "  INQUIRY: $INQ"
fi

# ---------- 第 1 级: 固件宣告 (VPD, 纯只读) ----------
head_ "第 1 级 · 固件宣告 (VPD)"
if [ $MISSING_SG -eq 1 ]; then
    warn "跳过 (缺 sg3_utils)"
else
    LBPV=$(sg_vpd -p lbpv "$DEV" 2>/dev/null)
    if [ -z "$LBPV" ]; then
        warn "无法读取 Logical Block Provisioning VPD 页 —— 固件不支持该页"
        R_LBPU="?"; R_PROVTYPE="?"
    else
        R_LBPU=$(echo "$LBPV"    | awk -F'[= ]' '/LBPU=/{print $2}')
        R_LBPWS=$(echo "$LBPV"   | awk -F'[= ]' '/LBPWS=/{print $2}')
        R_LBPWS10=$(echo "$LBPV" | awk -F'[= ]' '/LBPWS10=/{print $2}')
        R_PROVTYPE=$(echo "$LBPV" | awk -F': ' '/Provisioning type/{print $2}')
        info "$LBPV" | sed 's/^/    /'
        [ "$R_LBPU" = "1" ]    && ok "固件宣告支持 UNMAP 命令 (LBPU=1)" || warn "LBPU=$R_LBPU"
        [ "$R_LBPWS" = "1" ] || [ "$R_LBPWS10" = "1" ] \
            && ok "固件宣告支持 WRITE SAME unmap" \
            || info "  ℹ️  不支持 WRITE SAME unmap (LBPWS=$R_LBPWS LBPWS10=$R_LBPWS10)"
    fi
    BL=$(sg_vpd -p bl "$DEV" 2>/dev/null)
    R_MAXDESC=$(echo "$BL" | awk -F': ' '/Maximum unmap block descriptor count/{print $2}')
    [ -n "$R_MAXDESC" ] && info "  ℹ️  单命令最大描述符数: $R_MAXDESC"
    kv lbpu "$R_LBPU"; kv provisioning_type "$R_PROVTYPE"
fi

# ---------- 第 2 级: 内核政策 (sysfs, 纯只读) ----------
head_ "第 2 级 · 内核政策 (sysfs)"
R_DMAX=$(sysq discard_max_bytes)
R_DMAXHW=$(sysq discard_max_hw_bytes)
R_DGRAN=$(sysq discard_granularity)
R_DZERO=$(sysq discard_zeroes_data)
R_PROV=$(sd_attr provisioning_mode)
R_THIN=$(sd_attr thin_provisioning)
info "  discard_max_bytes      = $R_DMAX   (0 = 当前不可用)"
info "  discard_max_hw_bytes   = $R_DMAXHW   (硬件上报能力)"
info "  discard_granularity    = $R_DGRAN"
info "  discard_zeroes_data    = $R_DZERO   (1 = 保证 trim 后读零/DZAT)"
info "  provisioning_mode      = $R_PROV"
info "  thin_provisioning      = $R_THIN"
kv discard_max_bytes "$R_DMAX"; kv discard_max_hw_bytes "$R_DMAXHW"
kv provisioning_mode "$R_PROV"; kv discard_zeroes_data "$R_DZERO"

POLICY_NOTE=""
if [ "$R_DMAX" != "0" ] && [ "$R_DMAX" != "?" ]; then
    ok "内核 discard 已启用 (fstrim/-o discard 直接可用)"
    POLICY="ready"
elif [ "$R_DMAXHW" != "0" ] && [ "$R_DMAXHW" != "?" ]; then
    warn "硬件上报了能力 ($R_DMAXHW) 但被策略压低到 0"
    POLICY="capped"
else
    if [ "$R_PROV" = "full" ]; then
        warn "provisioning_mode=full —— 内核对 'provisioning type 未知' 设备的保守默认 (kernel 6.x+)"
        POLICY="conservative_off"
    else
        warn "硬件层未上报 discard 能力, 且 provisioning_mode=$R_PROV"
        POLICY="hw_silent"
    fi
fi
case "$POLICY" in
    ready)
        POLICY_NOTE="无需修复" ;;
    capped|conservative_off)
        POLICY_NOTE="可解封: echo unmap | sudo tee /sys/block/$DEVNODE/device/scsi_disk/*/provisioning_mode"
        info "  🔧 $POLICY_NOTE" ;;
    hw_silent)
        POLICY_NOTE="内核未建立 provisioning 通道; 固件若宣告 LBPU=1, 可尝试 --fix 或第 3 级 SG_IO 直测"
        info "  ℹ️  $POLICY_NOTE" ;;
esac
kv policy "$POLICY"

# ---------- --fix: 解封 ----------
if [ $DO_FIX -eq 1 ]; then
    head_ "解封内核政策"
    if echo unmap | tee /sys/block/"$DEVNODE"/device/scsi_disk/*/provisioning_mode >/dev/null 2>&1; then
        NEWMAX=$(sysq discard_max_bytes)
        if [ "$NEWMAX" != "0" ] && [ "$NEWMAX" != "?" ]; then
            ok "解封成功: discard_max_bytes = $NEWMAX"
            R_DMAX="$NEWMAX"; R_PROV="unmap"; POLICY="ready"
            if [ -n "$VID" ] && [ -n "$PID" ]; then
                info "  固化 udev 规则 (/etc/udev/rules.d/10-usb-unmap.rules):"
                RULE="ACTION==\"add|change\", SUBSYSTEM==\"scsi_disk\", ATTRS{idVendor}==\"$VID\", ATTRS{idProduct}==\"$PID\", ATTR{provisioning_mode}=\"unmap\""
                info "    $RULE"
                printf "  写入规则文件? [y/N] "
                [ $ASSUME_YES -eq 1 ] && a=y || read -r a
                if [ "$a" = "y" ]; then
                    echo "$RULE" >> /etc/udev/rules.d/10-usb-unmap.rules
                    udevadm control --reload
                    ok "已写入并 reload"
                fi
            fi
        else
            warn "写入了 unmap 但 discard_max_bytes 仍为 0 —— 设备未按预期响应"
        fi
    else
        bad "写入 provisioning_mode 失败 (设备可能不支持修改)"
    fi
    kv discard_max_bytes "$R_DMAX"; kv provisioning_mode "$R_PROV"; kv policy "$POLICY"
fi

# ---------- 第 3 级: 执行验证 (--live) ----------
LIVE_VERDICT="未执行 (未开启 --live)"
if [ $DO_LIVE -eq 1 ]; then
    head_ "第 3 级 · 执行验证 (图案读回法)"

    # 3.1 找到设备上可写的挂载文件系统
    MNT=""
    while read -r src mnt; do
        [ -z "$mnt" ] && continue
        parent=$(lsblk -no PKNAME "$src" 2>/dev/null || true)
        [ "$parent" = "$DEVNODE" ] || continue
        [ -w "$mnt" ] || continue
        avail=$(df -B1 --output=avail "$mnt" 2>/dev/null | tail -1 | tr -d ' ')
        [ "${avail:-0}" -gt $(( (PATTERN_SIZE_MB + 64) * 1048576 )) ] && { MNT="$mnt"; PART="$src"; break; }
    done < <(findmnt -rn -o SOURCE,TARGET 2>/dev/null)

    if [ -z "$MNT" ]; then
        bad "未找到 $DEV 上可写且空间足够的已挂载文件系统"
        info  "     请先挂载某个分区 (需 ${PATTERN_SIZE_MB}MB+ 空闲), 再重跑 --live"
    else
        info "  靶场: $MNT ($PART)"
        [ $ASSUME_YES -eq 1 ] || {
            printf "  将向该文件系统写入并删除一个 %dMB 图案文件, 并对其原占用的 1MB 空闲区 UNMAP。继续? [y/N] " "$PATTERN_SIZE_MB"
            read -r a; [ "$a" = "y" ] || die "用户取消"
        }

        PAT="$MNT/.unmap-doctor-pattern.bin"
        info "  [1/5] 写入图案文件..."
        if have python3; then
            python3 -c "open('$PAT','wb').write(b'\x5A'*($PATTERN_SIZE_MB*1048576))" || die "图案写入失败"
        else
            dd if=/dev/zero bs=1M count=$PATTERN_SIZE_MB 2>/dev/null | tr '\000' '\132' > "$PAT" || die "图案写入失败"
        fi
        sync

        # 3.2 定位图案物理位置: 优先 FIEMAP (快), 失败则全盘扫描 (慢)
        PARTNODE=$(basename "$PART")
        PSTART_SEC=$(cat /sys/class/block/"$PARTNODE"/start)
        ABS_OFF=""
        if have filefrag; then
            read -r PSTART_BLOCKS PLEN_BLOCKS FBS <<<"$(filefrag -v "$PAT" 2>/dev/null | awk '
                /block size|blocksize/ {bs=$NF; gsub(/[^0-9]/,"",bs)}
                /^[[:space:]]*[0-9]+:/ {
                    p=$4; sub(/\.\..*/,"",p);
                    l=$6; sub(/:.*/,"",l);
                    if (p!="") {print p, l, bs; exit}
                }')"
            if [ -n "${PSTART_BLOCKS:-}" ] && [ -n "${FBS:-}" ] && [ "${FBS:-0}" -ge 512 ]; then
                ABS_OFF=$(( PSTART_SEC * 512 + PSTART_BLOCKS * FBS ))
                EXT_BYTES=$(( ${PLEN_BLOCKS:-0} * FBS ))
                info "  [2/5] FIEMAP 定位: 文件系统内偏移 $((PSTART_BLOCKS*FBS)) 字节, 连续 ${EXT_BYTES} 字节"
            fi
        fi

        # 3.3 删除文件 (图案留在空闲簇), 然后 UNMAP + 读回
        rm -f "$PAT"; sync

        if [ -n "$ABS_OFF" ]; then
            # 安全预检: 该偏移前 4KB 必须真的是图案, 防止 FIEMAP 异常误伤数据
            PRE=$(dd if="$DEV" bs=4096 iflag=skip_bytes skip=$ABS_OFF count=1 2>/dev/null | tr -d '\132' | wc -c)
            if [ "$PRE" != "0" ]; then
                bad "安全预检失败: FIEMAP 指向的区域不是预期图案, 已中止 (未发 UNMAP)"
                ABS_OFF=""
            fi
        fi

        if [ -z "$ABS_OFF" ]; then
            warn "无法通过 FIEMAP 定位, 本版本未内置全盘扫描, 第 3 级跳过"
            warn "可换用专用工具 unmap-live (含 GPT 扫描) 完成验证"
            LIVE_VERDICT="跳过"
        else
            LBA=$(( ABS_OFF / 512 ))
            info "  [3/5] 对 LBA $LBA (偏移 $ABS_OFF) 发 1MB UNMAP (SG_IO 直发, 绕过块层政策)..."
            if [ $MISSING_SG -eq 1 ]; then
                die "sg_unmap 不可用 (sg3_utils 未安装)"
            fi
            sg_unmap --force --lba=$LBA --num=2048 "$DEV" >/dev/null 2>&1
            RC=$?
            if [ $RC -ne 0 ]; then
                sg_unmap --lba=$LBA --num=2048 "$DEV"
                RC=$?
            fi
            info "  [4/5] UNMAP 返回码 RC=$RC"

            info "  [5/5] 读回验证..."
            NONZERO=$(dd if="$DEV" bs=1M iflag=skip_bytes,count_bytes skip=$ABS_OFF count=$CHUNK 2>/dev/null | tr -d '\000' | wc -c)
            NONPAT=$(dd  if="$DEV" bs=1M iflag=skip_bytes,count_bytes skip=$ABS_OFF count=$CHUNK 2>/dev/null | tr -d '\132' | wc -c)

            if [ "$NONZERO" = "0" ]; then
                ok "TRIM-EXECUTED — 读回全零, SSD 真的执行了 UNMAP"
                LIVE_VERDICT="executed"
            elif [ "$NONPAT" = "0" ]; then
                if [ "$R_DZERO" = "0" ]; then
                    warn "读回仍是图案 —— 但 discard_zeroes_data=0, 也可能设备不保证读零, 建议交叉验证"
                    LIVE_VERDICT="inconclusive"
                else
                    bad "TRIM-SWALLOWED — 命令${RC:+已受理}但数据原样, UNMAP 被链路吞掉"
                    LIVE_VERDICT="swallowed"
                fi
            else
                warn "读回混合 (非零字节 $NONZERO, 非图案字节 $NONPAT) — 结果不明确"
                LIVE_VERDICT="mixed"
            fi
        fi
    fi
    kv live_verdict "$LIVE_VERDICT"
fi

# ---------- 综合结论 ----------
head_ "综合结论"
if [ "$LIVE_VERDICT" = "executed" ]; then
    R_VERDICT="CAPABLE"
    ok "该设备 UNMAP 全链路可用 (第 3 级实测执行)"
    [ "$POLICY" != "ready" ] && warn "但内核政策未放行 —— 用 --fix 解封后可日常使用 fstrim"
elif [ "$LIVE_VERDICT" = "swallowed" ]; then
    R_VERDICT="SWALLOWED"
    bad "固件/链路吞 UNMAP (命令受理但不执行) —— 该设备无法 TRIM"
elif [ "$LIVE_VERDICT" = "inconclusive" ]; then
    R_VERDICT="INCONCLUSIVE"
    warn "无法确证 (设备可能不保证 trim 后读零)"
elif [ "$R_DMAX" != "0" ] && [ "$R_DMAX" != "?" ] && [ "$R_LBPU" = "1" ]; then
    R_VERDICT="LIKELY"
    ok "固件宣告支持且内核已放行 —— 大概率可用; 建议 --live 做执行级终审"
elif [ "$POLICY" = "capped" ] || [ "$POLICY" = "conservative_off" ]; then
    R_VERDICT="POLICY_BLOCKED"
    warn "硬件可能支持, 但被内核政策禁用 —— $POLICY_NOTE"
elif [ "$R_LBPU" = "1" ]; then
    R_VERDICT="DECLARED"
    warn "固件宣告支持但内核未配置 —— 建议 --live 直接 SG_IO 终审 (绕过政策)"
else
    R_VERDICT="UNKNOWN"
    ask "证据不足, 建议: --live 执行级验证"
fi
kv verdict "$R_VERDICT"

[ $JSON -eq 1 ] && printf '%s\n' "${KV[@]}"
exit 0
