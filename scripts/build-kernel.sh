#!/usr/bin/env bash
# 下載、設定並編譯本專案用的 arm64 除錯 kernel。
#
# 用法：scripts/build-kernel.sh [config|build|all]（預設 all）
#   config  只產生 .config（下載 + 設定 + 檢查）
#   build   用現有的 .config 編譯
#
# 結果：build/linux -> build/linux-<版本>，映像檔在 build/linux/arch/arm64/boot/Image
# 講解：docs/lessons/stage-0-env.md
set -euo pipefail

KVER=6.18.54                                  # 和 Raspberry Pi 官方 kernel 同一條 LTS（rpi-6.18.y）
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=$ROOT/build
KSRC=$BUILD/linux-$KVER
FRAGMENT=$ROOT/config/lab.config

# 每次呼叫 make 都要帶這兩個變數：
#   ARCH           目標架構，決定用 arch/arm64/ 下的程式碼與設定
#   CROSS_COMPILE  工具鏈前綴，make 會呼叫 aarch64-linux-gnu-gcc、aarch64-linux-gnu-ld ...
MAKE_ARGS=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)")

# 使用者的 Cloudflare WARP proxy（若有在跑），下載較快
proxy_env() {
	if (exec 3<>/dev/tcp/127.0.0.1/40000) 2>/dev/null; then
		export HTTPS_PROXY=socks5h://127.0.0.1:40000 HTTP_PROXY=socks5h://127.0.0.1:40000
	fi
}

fetch() {
	[ -d "$KSRC" ] && return
	local url=https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x
	mkdir -p "$BUILD/dl"
	(
		cd "$BUILD/dl"
		proxy_env
		curl -fL -C - -O "$url/linux-$KVER.tar.xz"
		curl -fsSLO "$url/sha256sums.asc"
		# 確認下載的檔案沒有損壞或被竄改（只比對雜湊；沒有驗 GPG 簽章）
		grep " linux-$KVER.tar.xz\$" sha256sums.asc | sha256sum -c
	)
	tar -C "$BUILD" -xf "$BUILD/dl/linux-$KVER.tar.xz"
}

configure() {
	cd "$KSRC"
	# 1. 從 arm64 官方預設設定開始，它已支援 QEMU virt 需要的硬體（PL011 UART、virtio、PCIe）
	make "${MAKE_ARGS[@]}" defconfig
	# 2. 把所有 =m 改成 =n：defconfig 會編幾千個用不到的 module，關掉可以大幅縮短編譯時間
	make "${MAKE_ARGS[@]}" mod2noconfig
	# 3. 合併本專案的片段（-m：只合併，不重新跑預設值）
	scripts/kconfig/merge_config.sh -m .config "$FRAGMENT"
	# 4. 補齊相依選項的預設值。如果片段裡某個選項的相依條件不成立，它會在這一步被默默拿掉
	make "${MAKE_ARGS[@]}" olddefconfig
	# 5. 所以要逐項檢查，確定片段裡的每個選項真的生效
	check_config
}

check_config() {
	local line sym bad=0
	while IFS= read -r line; do
		case "$line" in
		CONFIG_*=*)
			grep -qxF "$line" .config || { echo "!! 沒生效：$line" >&2; bad=1; } ;;
		"# CONFIG_"*" is not set")
			sym=${line#\# }; sym=${sym%% *}
			! grep -q "^$sym=" .config || { echo "!! 沒關掉：$sym" >&2; bad=1; } ;;
		esac
	done <"$FRAGMENT"
	[ "$bad" -eq 0 ] || { echo "設定檢查失敗" >&2; exit 1; }
	echo "設定檢查通過：片段裡的選項全部生效"
}

build() {
	cd "$KSRC"
	# Image：kernel 映像；modules：產生 Module.symvers，out-of-tree module 靠它解析 kernel 匯出的符號
	# scripts_gdb：GDB 輔助腳本（lx-dmesg、lx-symbols 等）
	make "${MAKE_ARGS[@]}" Image modules scripts_gdb
	ln -sfn "linux-$KVER" "$BUILD/linux"
	echo "完成：$KSRC/arch/arm64/boot/Image（$(make -s kernelrelease)）"
}

case "${1:-all}" in
config) fetch; configure ;;
build) build ;;
all) fetch; configure; build ;;
*) echo "用法：$0 [config|build|all]" >&2; exit 2 ;;
esac
