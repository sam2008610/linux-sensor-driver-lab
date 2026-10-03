#!/usr/bin/env bash
# 編譯靜態連結的 busybox，打包成 initramfs。
#
# 用法：scripts/mkinitramfs.sh
# 前提：已執行 scripts/build-kernel.sh（要用 kernel 樹裡的 usr/gen_init_cpio）
# 結果：build/initramfs.cpio.gz
# 講解：docs/lessons/stage-0-env.md 第 4 節
set -euo pipefail

BBVER=1.38.0
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=$ROOT/build
BBSRC=$BUILD/busybox-$BBVER
KSRC=$BUILD/linux
OUT=$BUILD/initramfs.cpio.gz

proxy_env() {
	if (exec 3<>/dev/tcp/127.0.0.1/40000) 2>/dev/null; then
		export HTTPS_PROXY=socks5h://127.0.0.1:40000 HTTP_PROXY=socks5h://127.0.0.1:40000
	fi
}

fetch() {
	[ -d "$BBSRC" ] && return
	mkdir -p "$BUILD/dl"
	(
		cd "$BUILD/dl"
		proxy_env
		curl -fL -C - -O "https://busybox.net/downloads/busybox-$BBVER.tar.bz2"
		curl -fsSLO "https://busybox.net/downloads/busybox-$BBVER.tar.bz2.sha256"
		sha256sum -c "busybox-$BBVER.tar.bz2.sha256"
	)
	tar -C "$BUILD" -xf "$BUILD/dl/busybox-$BBVER.tar.bz2"
}

build_busybox() {
	cd "$BBSRC"
	[ -x busybox ] && return
	make defconfig
	# 靜態連結：initramfs 裡沒有 libc 的 .so 和 dynamic loader，動態連結的程式跑不起來
	sed -i 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' .config
	# tc（流量控制）用到 TCA_CBQ_* 定義，cross 工具鏈附的 kernel header 已經沒有，會編譯失敗；本專案用不到
	sed -i 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' .config
	grep -qx 'CONFIG_STATIC=y' .config
	make CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)"
}

pack() {
	local list=$BUILD/initramfs.list
	# gen_init_cpio 依照這份清單產生 cpio 封存檔。
	# 好處：用清單描述 /dev/console 這類裝置節點，不需要 root 權限去 mknod。
	cat >"$list" <<-EOF
		dir  /bin            0755 0 0
		dir  /sbin           0755 0 0
		dir  /usr            0755 0 0
		dir  /usr/bin        0755 0 0
		dir  /usr/sbin       0755 0 0
		dir  /dev            0755 0 0
		nod  /dev/console    0600 0 0 c 5 1
		dir  /proc           0755 0 0
		dir  /sys            0755 0 0
		dir  /mnt            0755 0 0
		dir  /tmp            1777 0 0
		dir  /root           0700 0 0
		file /bin/busybox    $BBSRC/busybox                0755 0 0
		file /init           $ROOT/scripts/initramfs/init  0755 0 0
	EOF
	"$KSRC/usr/gen_init_cpio" "$list" | gzip -9 >"$OUT"
	echo "完成：$OUT（$(du -h "$OUT" | cut -f1)）"
}

fetch
build_busybox
file "$BBSRC/busybox" | grep -q 'ARM aarch64.*statically linked' ||
	{ echo "!! busybox 不是靜態連結的 aarch64 執行檔" >&2; exit 1; }
pack
