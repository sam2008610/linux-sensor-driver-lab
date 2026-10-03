# 階段 0：環境與 kernel 建置

> 對應 issue #1。查證基準：Linux 6.18.54（`build/linux`），下文的「檔案:行號」都指這個版本。

## 1. 整體觀念

寫 driver 之前，要先回答三個問題：

1. **kernel 從哪來？** 自己從原始碼編一個，才能打開 lockdep、KASAN 這些一般發行版不會開的除錯功能。
2. **kernel 開機後要執行什麼？** kernel 只是核心，開機最後一步要交棒給一個 user space 程式。我們用一個很小的 initramfs（裡面只有 busybox）當作根檔案系統。
3. **kernel 跑在哪？** 在 QEMU 模擬出來的 arm64 機器上。driver 寫錯讓 kernel 當掉，也只是重開 QEMU。

你的 module 最後就是在這台虛擬機器裡被 `insmod`。

## 2. 全貌

```
host（x86_64，你的電腦）
│
├─ build/linux（kernel 原始碼）
│     │  scripts/build-kernel.sh：設定 + cross compile
│     ▼
│   arch/arm64/boot/Image ─────────────┐
│   Module.symvers（給你的 module 用） │
│                                      │
├─ busybox（static）                   │
│     │  scripts/mkinitramfs.sh        │
│     ▼                                │
│   initramfs.cpio.gz ─────────────────┤
│                                      ▼
│                   scripts/run-qemu.sh：QEMU virt（Cortex-A72）
│                     ├─ 載入 Image、initramfs
│                     ├─ 自動產生 DTB（描述虛擬硬體）交給 kernel
│                     └─ 9p 共享資料夾：repo ⇄ guest 的 /mnt/host
│                                      │
│                                      ▼
│                   kernel 開機 → 執行 /init → busybox shell
│                                      │
└─ modules/hello/hello.ko ──(9p)──→ insmod /mnt/host/modules/hello/hello.ko
```

---

## 3. A：編譯 kernel（`scripts/build-kernel.sh`）

### 3.1 Kconfig 與 `.config`

- kernel 有上萬個選項，每個都定義在某個 `Kconfig` 檔案裡，例如 `config PROVE_LOCKING` 定義在 `lib/Kconfig.debug`。
- 選出來的結果存在 `.config`，編譯時會依它決定哪些程式碼要編。
- 每個選項的值：
  - `=y`：編進 kernel 本體（`Image`）
  - `=m`：編成獨立的 `.ko` module，需要時再載入
  - `is not set`：不編
- 選項之間有相依關係：
  - `depends on X`：X 成立，這個選項才能開
  - `select X`：開了這個選項，就強制把 X 也開起來
- 有 prompt 的選項（`bool "說明文字"`）才能直接設定。沒有 prompt 的（例如 `REGMAP`）只能靠別的選項 `select` 進來。

### 3.2 腳本產生 `.config` 的五個步驟

| 步驟 | 指令 | 為什麼 |
|---|---|---|
| 1 | `make defconfig` | 從 arm64 官方預設設定開始，已經支援 QEMU virt 的硬體（PL011 UART、virtio、PCIe） |
| 2 | `make mod2noconfig` | 把所有 `=m` 改成 `=n`。defconfig 會編幾千個用不到的 module，關掉後實測整個編譯只要 3 分 21 秒（16 核） |
| 3 | `merge_config.sh -m .config config/lab.config` | 合併本專案要額外開的選項 |
| 4 | `make olddefconfig` | 幫新出現的相依選項補上預設值 |
| 5 | `check_config` | 逐項確認 `lab.config` 裡的選項真的生效 |

**第 5 步很重要**：如果某個選項的 `depends on` 不成立，`olddefconfig` 會**直接把它拿掉，而且不會報錯**。

### 3.3 `config/lab.config` 開了什麼

| 群組 | 選項 | 用途 |
|---|---|---|
| module | `MODULES`、`MODULE_UNLOAD` | 能 `insmod`／`rmmod` |
| 開機 | `BLK_DEV_INITRD`、`DEVTMPFS` | 支援 initramfs、kernel 自動建立 `/dev` 下的裝置節點 |
| 共享資料夾 | `VIRTIO_PCI`、`NET_9P`、`NET_9P_VIRTIO`、`9P_FS` | guest 直接讀到 host 上剛編好的 `.ko` |
| 除錯基本 | `DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT`、`GDB_SCRIPTS`、`KALLSYMS_ALL`、`DYNAMIC_DEBUG` | 有除錯資訊，oops 的位置才能對回原始碼行號；可以用 GDB 連進 kernel |
| 鎖 | `PROVE_LOCKING`、`DEBUG_ATOMIC_SLEEP` | lockdep；在不能 sleep 的地方 sleep 會報錯（階段 3、4 主角） |
| 記憶體 | `KASAN`、`KASAN_GENERIC` | 抓越界存取、use-after-free |
| 模擬 GPIO | `GPIO_SIM`（加上 `GPIOLIB`、`CONFIGFS_FS`） | 階段 3 的中斷來源。已確認支援 DT：`drivers/gpio/gpio-sim.c:534` 有 `compatible = "gpio-simulator"` |
| IIO 核心 | `IIO`、`IIO_BUFFER`、`IIO_TRIGGER`、`IIO_KFIFO_BUF`、`IIO_TRIGGERED_BUFFER`、`IIO_SYSFS_TRIGGER` | 階段 2、3 用。**必須是 `=y`**，原因見「想一想」第 1 題 |

另外確認了 `REGMAP=y`、`REGMAP_I2C=y` 已經被 defconfig 裡的其他 driver 帶進來，所以階段 2 和階段 7 可以直接用。

### 3.4 交叉編譯（cross compile）

```
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j16 Image modules scripts_gdb
```

- `ARCH=arm64`：用 `arch/arm64/` 底下的程式碼與設定。
- `CROSS_COMPILE=aarch64-linux-gnu-`：工具鏈前綴。make 原本要呼叫 `gcc`，會變成呼叫 `aarch64-linux-gnu-gcc`，在 x86 上產生 arm64 機器碼。
- **編你自己的 module 時也要帶這兩個變數**，而且要指向同一棵 kernel 樹。

### 3.5 編出來的東西

| 檔案 | 是什麼 |
|---|---|
| `arch/arm64/boot/Image` | kernel 本體（未壓縮），QEMU 直接載入 |
| `Module.symvers` | kernel 匯出給 module 用的所有符號，共 14090 個，每個都標示是 `EXPORT_SYMBOL` 還是 `EXPORT_SYMBOL_GPL`。編 module 時，modpost 用它檢查你呼叫的函式是否存在 |
| `vmlinux` | 有完整符號與除錯資訊的 ELF 檔，給 GDB 和 `decode_stacktrace.sh` 用 |

---

## 4. B：initramfs 與第一個 user space 程式（`scripts/mkinitramfs.sh`）

### 4.1 kernel 開機的最後一步

kernel 初始化完硬體後，要執行**第一個 user space 程式**，它的 PID 是 1：

- 有 initramfs 時，kernel 執行裡面的 `/init`（`init/main.c:165`：`ramdisk_execute_command = "/init"`）。
- PID 1 不能結束，否則 kernel 會 panic。

### 4.2 initramfs 是什麼

- 一個 cpio 封存檔（可以壓縮），kernel 開機時把它解開到記憶體裡，當作根檔案系統。
- 我們的 initramfs 只放兩個檔案：`/bin/busybox` 和 `/init`，加上幾個空目錄和 `/dev/console`，壓縮後 1.2MB。
- busybox 是**一個**執行檔，提供 `sh`、`mount`、`insmod`、`dmesg` 等幾百個指令（applet）。它看自己被叫成什麼名字，就執行哪個指令，所以只要建立 `/bin/sh -> busybox` 這類 symlink 就能用。
- busybox 要**靜態連結**（static），原因見「想一想」第 2 題。

### 4.3 `mkinitramfs.sh` 的三步

1. **下載 busybox 1.38.0**，比對雜湊值。
2. **編譯**：`make defconfig` 之後改兩個選項，再 cross compile（實測約 9 秒）：
   - `CONFIG_STATIC=y`：靜態連結
   - 關掉 `CONFIG_TC`：busybox 的 `networking/tc.c` 用到 `TCA_CBQ_*`，但 cross 工具鏈附的 kernel header（7.0 版）已經沒有這些定義，不關會編譯失敗
3. **打包**：用 kernel 樹裡的 `usr/gen_init_cpio`。它讀一份文字清單（`dir`、`file`、`nod` 等），直接產生 cpio。好處是 `/dev/console` 這種裝置節點寫在清單裡就好，**不需要 root 權限**去 `mknod`。kernel 自己內建的那份最小 initramfs 也是這樣產生的（`usr/default_cpio_list`）。

### 4.4 `/init` 要做的事（`scripts/initramfs/init`）

```
/bin/busybox --install -s                      # 為每個 applet 建立 symlink：/bin/sh、/bin/mount ...
mount -t proc     proc     /proc               # ps、/proc/interrupts
mount -t sysfs    sysfs    /sys                # 階段 1 起天天用：/sys/bus/platform、/sys/bus/iio
mount -t devtmpfs devtmpfs /dev                # /dev 下的裝置節點
mount -t configfs configfs /sys/kernel/config  # gpio-sim 的設定介面（階段 3）
mount -t debugfs  debugfs  /sys/kernel/debug   # dynamic debug 等除錯資訊
mount -t 9p -o trans=virtio,version=9p2000.L host /mnt/host   # host 的 repo
setsid cttyhack sh                             # 交給 shell
poweroff -f                                    # shell 結束後正常關機
```

幾個細節：

- `/dev` 必須手動掛載。`DEVTMPFS_MOUNT` 的說明寫得很清楚，它**對 initramfs 無效**（`drivers/base/Kconfig`，`config DEVTMPFS_MOUNT` 的 help）。
- `setsid cttyhack sh`：讓 shell 拿到 controlling terminal，不然按 `Ctrl-C` 中斷不了前景程式。
- 為什麼不寫 `exec sh`？`exec` 會讓 shell 取代 PID 1，你一輸入 `exit`，PID 1 就結束了，kernel 會 panic。現在的寫法是 shell 結束後，`/init` 繼續執行 `poweroff -f` 正常關機。

---

## 5. C：QEMU（`scripts/run-qemu.sh`）

| 參數 | 意義 |
|---|---|
| `-machine virt` | QEMU 的通用 arm64 虛擬機器，硬體都是 virtio 或標準元件 |
| `-cpu cortex-a72` | 和樹莓派 4 同一顆 CPU 核心 |
| `-smp 2 -m 2G` | 2 核、2GB。至少要 2 核，才會出現真正的並行，race 才有機會發生 |
| `-kernel Image -initrd initramfs.cpio.gz` | 直接載入 kernel 與 initramfs，不需要 bootloader |
| `-append "console=ttyAMA0 panic=-1"` | kernel 開機參數。virt 的 UART 是 PL011，Linux 給它的名字是 `ttyAMA0`；`panic=-1` 表示 panic 後立刻重開機 |
| `-no-reboot` | 搭配 `panic=-1`：guest 一要重開機，QEMU 就直接結束。所以 kernel panic 時你會回到 host 的 shell，panic 訊息留在終端機上 |
| `-nographic` | 不開視窗，console 直接接到你的終端機。離開按 `Ctrl-a x` |
| `-virtfs local,path=<repo>,mount_tag=host,...` | 把 repo 分享給 guest，對應 `/init` 裡的 `mount -t 9p ... host` |
| `-dtb <檔案>`（選用，`DTB=` 環境變數） | 用自己的 device tree 取代 QEMU 自動產生的，階段 1 起會用到 |
| `-s`／`-S`（選用，`GDB=1`／`GDB=wait`） | 開 GDB server（port 1234）；`-S` 讓 CPU 先暫停，等 GDB 連上再開機 |

用法：

```
scripts/run-qemu.sh                  # 一般開機
scripts/run-qemu.sh loglevel=8       # 後面的參數會加到 kernel 開機參數
DTB=build/lab.dtb scripts/run-qemu.sh
```

**DTB 從哪來？** QEMU 會依照模擬的硬體**自動產生** DTB，交給 kernel。階段 1 會把它匯出來（`-machine virt,dumpdtb=virt.dtb`）、加上我們自己的節點，再用 `-dtb` 傳回去。

**純模擬**：host 是 x86，guest 是 arm64，不能用 KVM 加速，QEMU 要逐條翻譯指令，再加上 KASAN，guest 跑起來會比實機慢。實測從開機到執行 `/init` 約 2.7 秒，日常使用沒問題，但做壓力測試時要記得這個差距。

**實測開機結果**：`uname -r` 是 `6.18.54-lab`、`nproc` 是 2，`/mnt/host` 看得到 repo。dmesg 有 `KernelAddressSanitizer initialized (generic)` 和 lockdep 的啟動訊息，整段開機沒有任何 warning。

---

## 6. D：你的 hello module

這部分由你寫，放在 `modules/hello/`。以下只列觀念和 API 名稱（提示階梯第 2 階），程式碼要你自己寫。

### 6.1 out-of-tree module 怎麼編

- 寫一個 `Kbuild`（或 `Makefile`），內容是 `obj-m := hello.o`，告訴 kbuild「把 `hello.c` 編成 module」。
- 編譯時「借用」kernel 樹的建置系統：

  ```
  make -C <kernel 樹> M=<你的 module 目錄> ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules
  ```

  `-C` 讓 make 先切換到 kernel 樹，`M=` 告訴它要編的 module 在哪裡。
- 參考：`Documentation/kbuild/modules.rst` 第 2、3 節。

### 6.2 會用到的東西

| 項目 | 查證位置 | 要想的事 |
|---|---|---|
| `module_init()`／`module_exit()` | `include/linux/module.h` | 載入和卸載時各呼叫哪個函式？init 回傳非 0 會怎樣？ |
| `__init`／`__exit` | `include/linux/init.h:45`、`:79` | 被放進 `.init.text` 段，載入完成後這段記憶體會被釋放 |
| `MODULE_LICENSE()` | `kernel/module/main.c:1238`、`:368` | 授權不相容 GPL 的 module 不能用 `EXPORT_SYMBOL_GPL` 的符號（`gplok` 為 false） |
| `MODULE_AUTHOR()`／`MODULE_DESCRIPTION()` | `include/linux/module.h` | `modinfo` 會顯示 |
| `module_param()` | `include/linux/moduleparam.h:131` | 三個參數：變數、型別、權限。權限非 0 時，會出現在 `/sys/module/<名稱>/parameters/` |
| `pr_info()` | `include/linux/printk.h` | 訊息進 kernel log，用 `dmesg` 看 |

### 6.3 驗收（issue #1）

- `insmod`／`rmmod` 時，dmesg 有對應訊息
- `modinfo hello.ko` 看得到參數與說明
- `insmod hello.ko <參數>=<值>` 後，值有反映在 dmesg 和 `/sys/module/hello/parameters/`

---

## 7. 常見誤解與坑

- **「`DEVTMPFS_MOUNT=y` 就會自動有 `/dev`」**：initramfs 開機時無效，要在 `/init` 手動 mount。
- **「`.config` 裡寫了就一定會開」**：相依條件不成立時，`olddefconfig` 會默默拿掉，所以要檢查。
- **用 A 版 kernel 編、在 B 版 kernel 載入**：module 裡記錄了編譯時的 kernel 版本與設定（vermagic，`include/linux/vermagic.h:41`），不一致就拒絕載入。這就是為什麼 module 一定要對著「正在跑的那棵 kernel 樹」編譯。
- **「out-of-tree module 可以在自己的 Kconfig 裡 `select` 需要的功能」**：不行。kernel 已經編好了，你需要的功能必須事先就在 kernel 裡（`=y`），或是以 module 形式先載入。
- **`insmod` 和 `modprobe` 一樣**：`insmod` 只載入你指定的那一個檔案，不處理相依；`modprobe` 會依 `modules.dep` 先載入相依的 module。
- **忘了寫 `MODULE_LICENSE`**：kernel 會被標記為 tainted，而且呼叫 GPL-only 函式會失敗。

---

## 8. 想一想

先自己想，想完再展開答案。

**1. `lab.config` 把 IIO 相關選項都設成 `=y`。假設改成 `CONFIG_IIO=m`，但 guest 裡沒有載入 `industrialio.ko`，這時對你的 IIO driver 執行 `insmod` 會發生什麼事？為什麼？**

<details><summary>答案</summary>

載入失敗，dmesg 會出現類似 `yourdrv: Unknown symbol devm_iio_device_alloc (err -2)` 的訊息（印出位置在 `kernel/module/main.c:1566`）。

原因：`devm_iio_device_alloc` 的程式碼在 IIO 核心裡（`drivers/iio/industrialio-core.c:1778` 用 `EXPORT_SYMBOL_GPL` 匯出）。`=m` 時，它在 `industrialio.ko` 裡；這個 module 沒載入，kernel 的符號表就找不到這個函式，你的 module 無法完成連結。`insmod` 不會自動載入相依的 module，`modprobe` 才會。

我們設 `=y`，這些函式就直接在 `Image` 裡，可以在 `Module.symvers` 看到 `devm_iio_device_alloc  vmlinux  EXPORT_SYMBOL_GPL`。
</details>

**2. 為什麼 busybox 要靜態連結？如果用動態連結會怎樣？**

<details><summary>答案</summary>

動態連結的程式執行時，需要 dynamic loader（`ld-linux-aarch64.so.1`）和 libc 的 `.so` 檔。我們的 initramfs 裡沒有放這些，所以 kernel 執行 `/init` 時會失敗，接著 panic（PID 1 起不來）。靜態連結把 libc 直接包進執行檔，initramfs 只要一個檔案就能動。
</details>

**3. 沒寫 `MODULE_LICENSE("GPL")` 的 module 呼叫 `devm_iio_device_alloc`，會發生什麼事？**

<details><summary>答案</summary>

一樣會 `Unknown symbol`。沒有宣告相容 GPL 的授權，module 會被標記 `TAINT_PROPRIETARY_MODULE`，查詢符號時 `gplok` 為 false（`kernel/module/main.c:1238`），而 `EXPORT_SYMBOL_GPL` 匯出的符號在 `gplok` 為 false 時會被跳過（同檔案 `:368`），所以等於找不到這個符號。
</details>

**4. 一個標了 `__init` 的函式，在 module 載入完成之後又被呼叫（例如被 `rmmod` 時的 exit 函式呼叫），會發生什麼事？**

<details><summary>答案</summary>

`__init` 函式放在 `.init.text` 段，module 初始化完成後這段記憶體就被釋放了。之後再呼叫，等於跳到已釋放的記憶體去執行，通常會造成 oops。編譯時 modpost 常會先用 section mismatch 警告提醒你。
</details>

**5. 為什麼 `run-qemu.sh` 至少要開 2 個 CPU 核心？只開 1 個核心時，race condition 就完全不會發生嗎？**

<details><summary>答案</summary>

多核才會有「兩段程式碼真的同時在跑」的狀況，最容易暴露 race。但單核也會有 race：開了 kernel preemption 時，一段程式碼可能被搶佔，換另一個 thread 進來執行；中斷也可能在任何時候打斷目前的程式碼。所以單核不代表安全，只是 race 比較難重現。階段 3、4 會再深入。
</details>

---

## 9. 延伸閱讀

- `Documentation/kbuild/modules.rst`：out-of-tree module 怎麼編（寫 hello module 前必讀）
- `Documentation/kbuild/kconfig-language.rst`：`depends on`、`select` 的完整語法
- `Documentation/filesystems/ramfs-rootfs-initramfs.rst`：initramfs 的原理
- `Documentation/admin-guide/kernel-parameters.txt`：所有開機參數（`console=`、`rdinit=`……）
- Bootlin kernel 講義「Linux kernel introduction」「Kernel modules」章節：https://bootlin.com/training/kernel/
