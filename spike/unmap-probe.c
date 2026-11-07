// unmap-probe.c — 探测 macOS 对 USB 桥的 UNMAP 支持
// 全部操作为只读或零长度空操作, 不会修改盘上任何数据
// 用法: sudo ./unmap-probe /dev/rdisk2
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/disk.h>

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/dev/rdisk2";
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return 1;
    }

    uint32_t blockSize = 0, physBlock = 0;
    uint64_t blockCount = 0;
    ioctl(fd, DKIOCGETBLOCKSIZE, &blockSize);
    ioctl(fd, DKIOCGETBLOCKCOUNT, &blockCount);
    if (ioctl(fd, DKIOCGETPHYSICALBLOCKSIZE, &physBlock) < 0)
        physBlock = 0;
    printf("PROBE-GEO blockSize=%u blockCount=%llu (%.1f GB) physBlock=%u\n",
           blockSize, blockCount, blockCount * (double)blockSize / 1e9, physBlock);

    uint32_t features = 0;
    if (ioctl(fd, DKIOCGETFEATURES, &features) < 0) {
        printf("PROBE-FEATURES error: %s (%d)\n", strerror(errno), errno);
    } else {
        printf("PROBE-FEATURES raw=0x%x BARRIER=%s PRIORITY=%s UNMAP=%s\n",
               features,
               (features & DK_FEATURE_BARRIER) ? "yes" : "no",
               (features & DK_FEATURE_PRIORITY) ? "yes" : "no",
               (features & DK_FEATURE_UNMAP) ? "YES" : "no");
    }

    dk_provision_extent_t ext[8];
    dk_provision_status_t ps;
    memset(ext, 0, sizeof ext);
    memset(&ps, 0, sizeof ps);
    ps.offset = 0;
    ps.length = 1024 * 1024;
    ps.extentsCount = 8;
    ps.extents = ext;
    if (ioctl(fd, DKIOCGETPROVISIONSTATUS, &ps) < 0) {
        printf("PROBE-PROVISION error: %s (%d)\n", strerror(errno), errno);
    } else {
        printf("PROBE-PROVISION extents=%u", ps.extentsCount);
        for (uint32_t i = 0; i < ps.extentsCount && i < 8; i++)
            printf(" [off=%llu len=%llu type=%u]", ext[i].offset, ext[i].length, ext[i].provisionType);
        printf("\n");
    }

    // 空 UNMAP: extentsCount=0, 不触碰任何扇区
    // 返回值用来判断 ioctl 通路: EINVAL/成功 = 通路存在; ENOTSUP/ENODEV = 不支持
    dk_unmap_t um;
    memset(&um, 0, sizeof um);
    if (ioctl(fd, DKIOCUNMAP, &um) < 0) {
        printf("PROBE-UNMAP-EMPTY error: %s (%d)\n", strerror(errno), errno);
    } else {
        printf("PROBE-UNMAP-EMPTY success (通路存在)\n");
    }

    close(fd);
    return 0;
}
