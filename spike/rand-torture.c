// rand-torture.c - macOS 4K 随机写压测 (无依赖, 直击 FTL 映射表)
// 用法: ./rand-torture <目标文件> <大小GB> <时长秒>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>

static double now(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <file> <sizeGB> <seconds>\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    long long sizeGB = atoll(argv[2]);
    int durSec = atoi(argv[3]);
    long long fileSize = sizeGB << 30;
    long long maxOff4k = fileSize / 4096;

    int fd = open(path, O_CREAT | O_RDWR, 0644);
    if (fd < 0) { perror("open"); return 1; }
    fcntl(fd, F_NOCACHE, 1);          // 绕过页面缓存
    fcntl(fd, F_RDAHEAD, 0);
    if (ftruncate(fd, fileSize) < 0) { perror("ftruncate"); return 1; }

    void *buf;
    if (posix_memalign(&buf, 4096, 4096)) { perror("memalign"); return 1; }
    srand(42);
    for (int i = 0; i < 1024; i++) ((unsigned *)buf)[i] = rand();

    double t0 = now(), win0 = t0;
    long long ops = 0, winOps = 0;
    fprintf(stderr, "目标 %lldGB, 随机写 %ds, 每5s报一次IOPS\n", sizeGB, durSec);

    while (now() - t0 < durSec) {
        off_t off = (off_t)(rand() % maxOff4k) * 4096;
        ssize_t w = pwrite(fd, buf, 4096, off);
        if (w != 4096) { fprintf(stderr, "pwrite: %s (op %lld)\n", strerror(errno), ops); return 1; }
        ops++; winOps++;
        if (ops % 1000 == 0) fdatasync(fd);   // 每1000个op压一次盘
        double t = now();
        if (t - win0 >= 5.0) {
            fprintf(stderr, "[%5.0fs] 累计 %lld ops | 当前窗口 %.0f IOPS (%.2f MB/s)\n",
                    t - t0, ops, winOps / (t - win0), winOps / (t - win0) * 4096 / 1e6);
            win0 = t; winOps = 0;
        }
    }
    fdatasync(fd);
    double el = now() - t0;
    fprintf(stderr, "RAND-RESULT ops=%lld 平均IOPS=%.0f 平均MBps=%.2f\n",
            ops, ops / el, ops / el * 4096 / 1e6);
    return 0;
}
