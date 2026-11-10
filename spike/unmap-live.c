// unmap-live.c — DKIOCUNMAP 活体验证 (四种模式)
//   unmap-live <dev>                  扫描图案 -> 发 UNMAP -> 读回 (默认全流程)
//   unmap-live <dev> --scan-only      只扫描并打印图案偏移 (供 VM 测试用)
//   unmap-live <dev> --verify <off>   只读回 1MB 统计字节构成
//   unmap-live <dev> --unmap <off>    对指定偏移发 UNMAP -> 读回 (带安全闸:
//                                     目标区必须 >99% 是 0x5A 图案, 否则拒绝动手)
// 用法: sudo ./unmap-live /dev/rdisk2 [模式]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/disk.h>

#define CHUNK (1024 * 1024)
#define PATTERN 0x5A

static const uint8_t MS_BASIC_DATA[16] = {
    0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44,
    0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7
};

static int all_byte(const uint8_t *buf, size_t n, uint8_t b) {
    for (size_t i = 0; i < n; i++)
        if (buf[i] != b) return 0;
    return 1;
}

static int find_exfat_range(int fd, uint32_t blockSize,
                            uint64_t *startByte, uint64_t *totalBytes) {
    uint8_t hdr[512];
    if (pread(fd, hdr, 512, 512) != 512 || memcmp(hdr, "EFI PART", 8)) {
        fprintf(stderr, "GPT 头读取失败\n");
        return -1;
    }
    uint64_t entryLBA, numEntries, entrySize;
    memcpy(&entryLBA, hdr + 72, 8);
    memcpy(&numEntries, hdr + 80, 4);
    memcpy(&entrySize, hdr + 84, 4);

    size_t tableBytes = (size_t)(numEntries * entrySize);
    uint8_t *table = malloc(tableBytes);
    if (pread(fd, table, tableBytes, entryLBA * blockSize) != (ssize_t)tableBytes) {
        fprintf(stderr, "GPT 分区表读取失败\n");
        free(table);
        return -1;
    }
    uint64_t partStart = 0, partEnd = 0;
    for (uint64_t i = 0; i < numEntries; i++) {
        uint8_t *ent = table + i * entrySize;
        if (!memcmp(ent, MS_BASIC_DATA, 16)) {
            uint64_t first, last;
            memcpy(&first, ent + 32, 8);
            memcpy(&last, ent + 40, 8);
            if (last - first > partEnd - partStart) {
                partStart = first;
                partEnd = last;
            }
        }
    }
    free(table);
    if (!partEnd) {
        fprintf(stderr, "未找到 exFAT 分区\n");
        return -1;
    }
    *startByte = partStart * blockSize;
    *totalBytes = (partEnd - partStart + 1) * blockSize;
    printf("LIVE-PART exFAT 分区: LBA %llu-%llu (%.1f GB)\n",
           partStart, partEnd, *totalBytes / 1e9);
    return 0;
}

static uint64_t scan_pattern(int fd, uint64_t startByte, uint64_t totalBytes, uint8_t *buf) {
    uint64_t scanned = 0;
    for (uint64_t off = startByte; off + CHUNK <= startByte + totalBytes; off += CHUNK) {
        if (pread(fd, buf, CHUNK, off) != CHUNK) break;
        scanned += CHUNK;
        if (all_byte(buf, CHUNK, PATTERN)) return off;
        if ((scanned % (16ULL << 30)) == 0)
            printf("LIVE-SCAN 已扫描 %llu GB...\n", scanned >> 30);
    }
    return 0;
}

static void verify(int fd, uint64_t off, uint8_t *buf) {
    if (pread(fd, buf, CHUNK, off) != CHUNK) {
        fprintf(stderr, "读回失败: %s\n", strerror(errno));
        return;
    }
    uint64_t zeros = 0, pattern = 0, other = 0;
    for (size_t i = 0; i < CHUNK; i++) {
        if (buf[i] == 0x00) zeros++;
        else if (buf[i] == PATTERN) pattern++;
        else other++;
    }
    printf("LIVE-READBACK zero=%llu pattern=%llu other=%llu\n", zeros, pattern, other);
    if (zeros > CHUNK * 99 / 100)
        printf("LIVE-VERDICT TRIM-EXECUTED — SSD 真的执行了 TRIM!\n");
    else if (pattern > CHUNK * 99 / 100)
        printf("LIVE-VERDICT TRIM-SWALLOWED — 数据还在, UNMAP 未到达 SSD\n");
    else
        printf("LIVE-VERDICT MIXED — 结果不明确\n");
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/dev/rdisk2";
    int scanOnly = argc > 2 && !strcmp(argv[2], "--scan-only");
    int verifyMode = argc > 3 && !strcmp(argv[2], "--verify");
    int unmapMode = argc > 3 && !strcmp(argv[2], "--unmap");

    int fd = open(path, (verifyMode || scanOnly) ? O_RDONLY : O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return 1;
    }
    fcntl(fd, F_NOCACHE, 1);
    fcntl(fd, F_RDAHEAD, 0);

    uint8_t *buf = malloc(CHUNK);

    if (verifyMode) {
        verify(fd, strtoull(argv[3], NULL, 10), buf);
        return 0;
    }

    if (unmapMode) {
        // 安全闸: UNMAP 会丢弃数据, 动手前必须确认目标区确实是我们埋的图案
        uint64_t off = strtoull(argv[3], NULL, 10);
        if (pread(fd, buf, CHUNK, off) != CHUNK) {
            fprintf(stderr, "预读失败: %s\n", strerror(errno));
            return 1;
        }
        uint64_t pat = 0;
        for (size_t i = 0; i < CHUNK; i++)
            if (buf[i] == PATTERN) pat++;
        printf("LIVE-PRECHECK 目标区 0x5A 占比 %.1f%%\n", pat * 100.0 / CHUNK);
        if (pat < CHUNK * 99 / 100) {
            printf("LIVE-VERDICT ABORT — 目标区不是图案, 拒绝 UNMAP (定位有误?)\n");
            return 1;
        }
        dk_extent_t extent = { .offset = off, .length = CHUNK };
        dk_unmap_t um;
        memset(&um, 0, sizeof um);
        um.extents = &extent;
        um.extentsCount = 1;
        if (ioctl(fd, DKIOCUNMAP, &um) < 0) {
            printf("LIVE-UNMAP error: %s (%d) — macOS 拒绝执行\n", strerror(errno), errno);
            return 1;
        }
        printf("LIVE-UNMAP ioctl 成功 (macOS 已受理)\n");
        verify(fd, off, buf);
        close(fd);
        return 0;
    }

    uint32_t blockSize = 512;
    uint64_t startByte, totalBytes;
    ioctl(fd, DKIOCGETBLOCKSIZE, &blockSize);
    if (find_exfat_range(fd, blockSize, &startByte, &totalBytes))
        return 1;

    uint64_t foundOff = scan_pattern(fd, startByte, totalBytes, buf);
    if (!foundOff) {
        printf("LIVE-FAIL 未找到 0x5A 图案区, 请确认图案文件已写入并删除\n");
        return 1;
    }
    printf("LIVE-FOUND 图案块 @ 偏移 %llu (%.2f GB), 大小 1MB\n",
           foundOff, foundOff / 1e9);

    if (scanOnly)
        return 0;

    dk_extent_t extent = { .offset = foundOff, .length = CHUNK };
    dk_unmap_t um;
    memset(&um, 0, sizeof um);
    um.extents = &extent;
    um.extentsCount = 1;
    if (ioctl(fd, DKIOCUNMAP, &um) < 0) {
        printf("LIVE-UNMAP error: %s (%d) — macOS 拒绝执行\n", strerror(errno), errno);
        return 1;
    }
    printf("LIVE-UNMAP ioctl 成功 (macOS 已受理)\n");
    verify(fd, foundOff, buf);
    close(fd);
    return 0;
}
