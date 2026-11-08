# qemu-env.sh — 被 spike 各脚本 source: 按本机架构选 QEMU 二进制/机器类型/串口设备
# Intel = x86_64 (q35 + ttyS0), Apple Silicon = arm64 (virt + ttyAMA0)
_QENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -m)" in
    arm64)  MACHINE="virt,accel=hvf"; CONSOLE=ttyAMA0; QEMU_BIN=qemu-system-aarch64 ;;
    x86_64) MACHINE="q35,accel=hvf";  CONSOLE=ttyS0;   QEMU_BIN=qemu-system-x86_64 ;;
    *) echo "qemu-env: 未知架构 $(uname -m)" >&2; exit 1 ;;
esac
QEMU="$_QENV_DIR/qemu-11.1.2/build/$QEMU_BIN"
