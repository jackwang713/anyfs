#!/usr/bin/env python3
# exfat-locate.py — 只读解析 GPT + exFAT 元数据, 算出文件的物理字节偏移 (免全盘扫描)
# 用法: ./exfat-locate.py /dev/rdisk7 .trim-live-pattern
# 输出: LOCATE-OFFSET=<整盘绝对字节偏移>  LOCATE-SIZE=<文件字节数>
# 全程 O_RDONLY; 解析错误的最坏后果是偏移算错, 由 unmap-live --unmap 的安全闸兜底拒动
import os, struct, sys

MS_BASIC_DATA = bytes([0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44,
                       0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7])

def die(msg):
    sys.exit(f"LOCATE-FAIL: {msg}")

def pread_al(fd, n, off):
    """裸盘字符设备要求偏移/长度按 512 扇区对齐, 不对齐直接 EINVAL"""
    start = off - off % 512
    end = (off + n + 511) // 512 * 512
    buf = os.pread(fd, end - start, start)
    return buf[off - start:off - start + n]

def main():
    if len(sys.argv) != 3:
        die("用法: exfat-locate.py <dev> <文件名>")
    dev, target = sys.argv[1], sys.argv[2]
    fd = os.open(dev, os.O_RDONLY)

    # --- 定位 exFAT 分区起点: 整盘走 GPT 找最大 MS Basic Data;
    #     设备本身就是分区 (anyFS 分区直通场景, 无 GPT) 则起点即 0 ---
    hdr = os.pread(fd, 512, 512)
    if hdr[:8] == b"EFI PART":
        entry_lba, num_entries, entry_size = struct.unpack_from("<QII", hdr, 72)
        table = os.pread(fd, num_entries * entry_size, entry_lba * 512)
        part_lba, part_size = 0, 0
        for i in range(num_entries):
            ent = table[i * entry_size:(i + 1) * entry_size]
            if ent[:16] == MS_BASIC_DATA:
                first, last = struct.unpack_from("<QQ", ent, 32)
                if last - first > part_size:
                    part_lba, part_size = first, last - first
        if not part_lba:
            die("未找到 Microsoft Basic Data 分区")
        part_base = part_lba * 512
    else:
        part_base = 0  # 直通分区设备: exFAT 从 0 开始

    # --- exFAT 启动扇区 ---
    boot = os.pread(fd, 512, part_base)
    if boot[3:11] != b"EXFAT   ":
        die("分区不是 exFAT")
    fat_off, heap_off = struct.unpack_from("<II", boot, 80)[0], struct.unpack_from("<I", boot, 88)[0]
    root_clus, = struct.unpack_from("<I", boot, 96)
    sector = 1 << boot[108]
    spc = 1 << boot[109]
    clus_bytes = spc * sector

    def clus_off(c):  # 簇号 → 分区内字节偏移 (簇从 2 起编)
        return (heap_off + (c - 2) * spc) * sector

    def fat_next(c):
        e = struct.unpack_from("<I", pread_al(fd, 4, part_base + fat_off * sector + c * 4))[0]
        return None if e >= 0xFFFFFFF8 else e

    def chain(start):
        out, c = [], start
        while c is not None and c >= 2:
            out.append(c)
            c = fat_next(c)
        return out

    # --- 走根目录找文件项 (0x85 文件 + 0xC0 流扩展 + 0xC1 文件名) ---
    for rc in chain(root_clus):
        data = os.pread(fd, clus_bytes, part_base + clus_off(rc))
        i = 0
        while i + 32 <= len(data):
            etype = data[i]
            if etype == 0x00:
                break
            if etype == 0x85:
                nsec = data[i + 1]
                ents = data[i:i + 32 * (1 + nsec)]
                if len(ents) < 32 * (1 + nsec):
                    break
                stream = ents[32:64]
                if stream[0] != 0xC0:
                    i += 32
                    continue
                name_len = stream[3]
                first_clus, = struct.unpack_from("<I", stream, 20)
                data_len, = struct.unpack_from("<Q", stream, 24)
                contiguous = bool(stream[1] & 0x02)
                name = b"".join(ents[64 + 32 * j + 2:64 + 32 * j + 32]
                                for j in range(nsec - 1)
                                if ents[64 + 32 * j] == 0xC1)[:name_len * 2]
                try:
                    name = name.decode("utf-16-le")
                except UnicodeDecodeError:
                    i += 32
                    continue
                if name == target:
                    # 空闲区碎片化的盘上文件可能分多段, 但检测只需一段连续 >=1MB:
                    # 走完整 FAT 链拼出全部连续段, 挑最长段
                    if contiguous:
                        total = (data_len + clus_bytes - 1) // clus_bytes
                        runs = [(first_clus, first_clus + total - 1)]
                    else:
                        clus_list = chain(first_clus)
                        runs, start = [], clus_list[0]
                        for a, b in zip(clus_list, clus_list[1:]):
                            if b != a + 1:
                                runs.append((start, a))
                                start = b
                        runs.append((start, clus_list[-1]))
                    need = 1024 * 1024 // clus_bytes + 1
                    best = max(runs, key=lambda r: r[1] - r[0])
                    span = best[1] - best[0] + 1
                    print(f"LOCATE-RUNS 共 {len(runs)} 段, 最长 {span * clus_bytes // 1048576}MB "
                          f"(簇 {clus_bytes // 1024}KB)", file=sys.stderr)
                    if span < need:
                        die(f"最长连续段只有 {span * clus_bytes // 1024}KB, 不足 1MB")
                    off = part_base + clus_off(best[0])
                    # 自检: 读 1MB 统计 0x5A 占比 (顺便验证缓存已落盘)
                    buf = os.pread(fd, 1024 * 1024, off)
                    ratio = buf.count(0x5A) * 100.0 / len(buf)
                    print(f"LOCATE-SELFTEST 目标 1MB 0x5A 占比 {ratio:.1f}%")
                    if ratio < 99.0:
                        die("自检失败: 目标区 0x5A 不足 99% (缓存未落盘或解析错位)")
                    print(f"LOCATE-OFFSET={off}")
                    print(f"LOCATE-RUNLEN={span * clus_bytes}")
                    print(f"LOCATE-SIZE={data_len}")
                    return
            i += 32 * (1 + (data[i + 1] if etype == 0x85 else 0))
        if i >= len(data) or data[i] == 0x00:
            break
    die(f"根目录里没找到 {target}")

main()
