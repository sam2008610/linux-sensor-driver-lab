#!/usr/bin/env bash
# 用 QEMU 開機本專案的 kernel + initramfs。
#
# 用法：scripts/run-qemu.sh [額外的 kernel 開機參數...]
# 環境變數：
#   DTB=<檔案>   用自己的 device tree 取代 QEMU 自動產生的（階段 1 起）
#   GDB=1        開 GDB server（port 1234），可用 gdb 連進 kernel
#   GDB=wait     同上，而且開機前先暫停，等 gdb 連上再繼續
# 離開：guest 裡輸入 exit（關機），或按 Ctrl-a 再按 x 強制結束 QEMU
# 講解：docs/lessons/stage-0-env.md 第 5 節
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=$ROOT/build/linux/arch/arm64/boot/Image
INITRD=$ROOT/build/initramfs.cpio.gz

[ -f "$IMAGE" ] || { echo "找不到 $IMAGE，先執行 scripts/build-kernel.sh" >&2; exit 1; }
[ -f "$INITRD" ] || { echo "找不到 $INITRD，先執行 scripts/mkinitramfs.sh" >&2; exit 1; }

args=(
	-machine virt                 # QEMU 的通用 arm64 虛擬機器
	-cpu cortex-a72               # 和樹莓派 4 同一顆 CPU 核心
	-smp 2                        # 至少 2 核，才有真正的並行
	-m 2G
	-nographic                    # 不開視窗，console 接到這個終端機
	-no-reboot                    # 搭配 panic=-1：kernel panic 時直接結束 QEMU，回到 host
	-kernel "$IMAGE"              # 直接載入 kernel，不需要 bootloader
	-initrd "$INITRD"
	-append "console=ttyAMA0 panic=-1 $*"   # virt 的 UART 是 PL011，Linux 叫它 ttyAMA0
	# 把 repo 分享給 guest，guest 的 /init 會把 mount_tag=host 掛到 /mnt/host
	-virtfs "local,path=$ROOT,mount_tag=host,security_model=none,id=host"
)

[ -n "${DTB:-}" ] && args+=(-dtb "$DTB")
case "${GDB:-}" in
1) args+=(-s) ;;
wait) args+=(-s -S) ;;
esac

exec qemu-system-aarch64 "${args[@]}"
