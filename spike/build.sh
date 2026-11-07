#!/bin/bash
# 构建 spike: 下载 Alpine ISO -> 提取 kernel/initrd -> swiftc 编译 -> ad-hoc 签名
set -e
cd "$(dirname "$0")"

ARCH=$(uname -m)
ALPINE_VER=3.21.3
ISO="alpine/alpine-virt.iso"
URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/${ARCH}/alpine-virt-${ALPINE_VER}-${ARCH}.iso"

mkdir -p alpine

if [ ! -f "$ISO" ]; then
    echo "下载 Alpine ISO: $URL"
    curl -fL "$URL" -o "$ISO"
fi

if [ ! -f alpine/vmlinuz-virt ]; then
    bsdtar -xf "$ISO" -C alpine boot/vmlinuz-virt boot/initramfs-virt
    mv alpine/boot/vmlinuz-virt alpine/boot/initramfs-virt alpine/
    rmdir alpine/boot
fi

swiftc -O main.swift -o spike
codesign --force --sign - --entitlements entitlements.plist spike
echo "构建完成: ./spike"
