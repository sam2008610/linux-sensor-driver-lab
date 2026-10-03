# linux-sensor-driver-lab

從零開始寫一個 Linux sensor driver 的學習專案，不使用現成的 driver。

涵蓋：device tree binding、probe/remove、threaded IRQ、IIO subsystem、
mutex／spinlock 並行處理，以及字元裝置（user/kernel 邊界）。

先在 QEMU（aarch64 `virt`）上以虛擬 sensor 開發，搭配開啟 lockdep、KASAN 的除錯 kernel；
之後搬到樹莓派 4 與真實的 I2C sensor。

## 快速開始

需要（Arch Linux）：`sudo pacman -S --needed qemu-system-aarch64 aarch64-linux-gnu-gcc bc`

```
scripts/build-kernel.sh    # 下載並編譯 arm64 除錯 kernel（6.18.54）
scripts/mkinitramfs.sh     # 編譯 busybox，打包 initramfs
scripts/run-qemu.sh        # 開機；repo 掛在 guest 的 /mnt/host，exit 關機
```

各步驟的講解見 [docs/lessons/stage-0-env.md](docs/lessons/stage-0-env.md)。

## 文件

- 學習計畫與進度：[docs/learning-plan.md](docs/learning-plan.md)
- 學習筆記：[docs/notes/](docs/notes/)
