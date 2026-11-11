#!/usr/bin/env python3
# exfat-bitdiff.py — exFAT 分配位图快照/差分定位 (原生深度检测的定位机制验证)
# 用法: exfat-bitdiff.py <dev> snapshot <输出文件>
#       exfat-bitdiff.py <dev> diff <快照A> <快照B>
# diff 输出: BITDIFF-RUNS 摘要(stderr) + BITDIFF-OFFSET=<分区绝对字节偏移> BITDIFF-RUNLEN=<字节>
# 原理: 写入文件 → 位图中对应簇位 0→1; 两快照差分即得新分配簇段,
#       免去目录树解析 (daemon 的 trimNative 已持有位图解析代码, 差分最省事)
import os, struct, sys

MS_BASIC_DATA = bytes([0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44,
                       0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7])

def die(msg):
    sys.exit(f"BITDIFF-FAIL: {msg}")

def pread_al(fd, n, off):
    """裸盘字符设备要求偏移/长度按 512 扇区对齐"""
    start = off - off % 512
    end = (off + n + 511) // 512 * 512
    buf = os.pread(fd, end - start, start)
    return buf[off - start:off - start + n]

class Exfat:
    def __init__(self, dev):
        self.fd = os.open(dev, os.O_RDONLY)
        hdr = os.pread(self.fd, 512, 512)
        if hdr[:8] == b"EFI PART":
            entry_lba, num_entries, entry_size = struct.unpack_from("<QII", hdr, 72)
            table = os.pread(self.fd, num_entries * entry_size, entry_lba * 512)
            part_lba, part_size = 0, 0
            for i in range(num_entries):
                ent = table[i * entry_size:(i + 1) * entry_size]
                if ent[:16] == MS_BASIC_DATA:
                    first, last = struct.unpack_from("<QQ", ent, 32)
                    if last - first > part_size:
                        part_lba, part_size = first, last - first
            if not part_lba:
                die("未找到 Microsoft Basic Data 分区")
            self.part_base = part_lba * 512
        else:
            self.part_base = 0
        boot = os.pread(self.fd, 512, self.part_base)
        if boot[3:11] != b"EXFAT   ":
            die("分区不是 exFAT")
        self.fat_off = struct.unpack_from("<I", boot, 80)[0]
        self.heap_off = struct.unpack_from("<I", boot, 88)[0]
        self.clus_cnt = struct.unpack_from("<I", boot, 92)[0]
        self.root_clus = struct.unpack_from("<I", boot, 96)[0]
        self.sector = 1 << boot[108]
        self.spc = 1 << boot[109]
        self.clus_bytes = self.spc * self.sector

    def clus_off(self, c):
        return (self.heap_off + (c - 2) * self.spc) * self.sector

    def fat_next(self, c):
        e = struct.unpack_from("<I", pread_al(self.fd, 4,
                self.part_base + self.fat_off * self.sector + c * 4))[0]
        return None if e >= 0xFFFFFFF8 else e

    def chain(self, start):
        out, c = [], start
        while c is not None and c >= 2:
            out.append(c)
            c = self.fat_next(c)
        return out

    def bitmap(self):
        """走根目录找 0x81 分配位图表项 → 读位图字节串"""
        for rc in self.chain(self.root_clus):
            data = os.pread(self.fd, self.clus_bytes, self.part_base + self.clus_off(rc))
            i = 0
            while i + 32 <= len(data):
                etype = data[i]
                if etype == 0x00:
                    break
                if etype == 0x81:
                    first_clus, length = struct.unpack_from("<IQ", data, i + 20)
                    nxt = self.fat_next(first_clus)
                    if nxt is not None:  # FAT 链有效 → 按链读; 否则按连续读
                        buf = b"".join(os.pread(self.fd, self.clus_bytes,
                                       self.part_base + self.clus_off(c))
                                       for c in self.chain(first_clus))
                    else:
                        buf = os.pread(self.fd, (length + self.clus_bytes - 1)
                                       // self.clus_bytes * self.clus_bytes,
                                       self.part_base + self.clus_off(first_clus))
                    return buf[:length]
                i += 32 * (1 + (data[i + 1] if etype == 0x85 else 0))
            if i >= len(data) or data[i] == 0x00:
                break
        die("根目录里没找到分配位图 (0x81)")

def main():
    if len(sys.argv) < 4:
        die("用法: exfat-bitdiff.py <dev> snapshot <文件> | diff <A> <B>")
    dev, mode = sys.argv[1], sys.argv[2]
    if mode == "snapshot":
        if len(sys.argv) != 4:
            die("snapshot 需要输出文件路径")
        bm = Exfat(dev).bitmap()
        with open(sys.argv[3], "wb") as f:
            f.write(bm)
        print(f"BITDIFF-SNAPSHOT {len(bm)} bytes → {sys.argv[3]}")
        return
    if mode != "diff" or len(sys.argv) != 5:
        die("用法: exfat-bitdiff.py <dev> snapshot <文件> | diff <A> <B>")
    # diff: 位 0→1 = 新分配簇
    a = open(sys.argv[3], "rb").read()
    b = open(sys.argv[4], "rb").read()
    if len(a) != len(b):
        die(f"两份位图长度不一致 ({len(a)} vs {len(b)})")
    ex = Exfat(dev)  # 仅为几何参数 (clus_off/clus_bytes)
    runs, start = [], None
    total_bits = min(len(a) * 8, ex.clus_cnt)
    for i in range(total_bits):
        newly = (b[i // 8] >> (i % 8)) & 1 and not (a[i // 8] >> (i % 8)) & 1
        if newly and start is None:
            start = i
        elif not newly and start is not None:
            runs.append((start, i - 1))
            start = None
    if start is not None:
        runs.append((start, total_bits - 1))
    need = 1048576 // ex.clus_bytes + (1 if 1048576 % ex.clus_bytes else 0)
    print(f"BITDIFF-RUNS 新分配 {len(runs)} 段 "
          f"(簇 {ex.clus_bytes // 1024}KB): " +
          ", ".join(f"{(e - s + 1) * ex.clus_bytes // 1048576}MB@clus{s + 2}"
                    for s, e in runs[:10]), file=sys.stderr)
    big = [(s, e) for s, e in runs if (e - s + 1) >= need]
    if not big:
        die("差分没有 ≥1MB 的新分配簇段 (文件没落盘? 写入走了缓存?)")
    s, e = max(big, key=lambda r: r[1] - r[0])
    print(f"BITDIFF-OFFSET={ex.part_base + ex.clus_off(s + 2)}")
    print(f"BITDIFF-RUNLEN={(e - s + 1) * ex.clus_bytes}")

main()
