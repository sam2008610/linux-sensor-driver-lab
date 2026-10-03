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
- 教材素材：[docs/lessons/](docs/lessons/)
- 學習筆記：[docs/notes/](docs/notes/)

## 教材怎麼來的

實際讀的課程由 [Heptabase](https://heptabase.com) 的 AI Tutor 生成
（Goal「The Road to Embedded Systems」，8 堂對應階段 0–7）：

1. 每個階段開始時，Claude 寫好該階段的素材 `docs/lessons/stage-N-<主題>.md`，
   API、Kconfig 都對照專案用的 kernel 原始碼查證，並註明出處。
2. 素材上傳到 Heptabase，作為 AI Tutor 的 Materials，由 AI Tutor 生成課程。
3. 課程生成後，Claude 透過 `heptabase` CLI 讀取課程內容，再對照 kernel 原始碼檢查一遍，
   有錯就指出來。
