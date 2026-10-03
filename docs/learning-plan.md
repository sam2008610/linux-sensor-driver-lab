# 學習計畫

目標：自己寫出一個完整的 Linux driver（DT binding、probe/remove、threaded IRQ、IIO、
並行處理），並且能在面試中具體解釋每個設計決定。

環境：QEMU aarch64 `virt` + 自己編的除錯 kernel（lockdep、KASAN、DEBUG_ATOMIC_SLEEP、gpio-sim）。
之後再搬到樹莓派 4 + 真實 sensor。

## 總覽

| 階段 | Issue | 主題 | 你做出來的東西 | 預估 | 目標週 | 實際 | 狀態 |
|---|---|---|---|---|---|---|---|
| 0 | #1 | 環境與 kernel 建置 | hello module 在 QEMU 裡載入／卸載 | 10h | W1 | | ⬜ |
| 1 | #2 | Device model、device tree、probe/remove | DT 節點觸發 probe 的 platform driver | 12h | W2 | | ⬜ |
| 2 | #3 | Regmap、IIO sysfs、mutex | 可從 sysfs 讀寫的虛擬 sensor | 15h | W3 | | ⬜ |
| 3 | #4 | 中斷：threaded IRQ、IIO trigger／buffer | 由 gpio-sim 中斷驅動的資料擷取 | 25h | W4–W5 | | ⬜ |
| 4 | #5 | 並行與除錯工具 | 壓力測試 + 故意製造的鎖錯誤實驗 | 15h | W6 | | ⬜ |
| 5 | #6 | 字元裝置：user/kernel 邊界 | misc device：blocking read、poll、ioctl | 15h | W7 | | ⬜ |
| 6 | #7 | 文件與模擬面試 | DT binding YAML、設計文件、模擬面試 | 12h | W8 | | ⬜ |
| — | | 緩衝 | 補落後的進度 | 15h | W9 | | |
| 7 | #8 | （之後）搬到樹莓派 + 真實 sensor | regmap 換成 I2C，接真的硬體 | 15h＋等貨 | W10 起 | | ⬜ |

狀態：⬜ 未開始　🟨 進行中　✅ 完成（驗收清單全勾、面試題答過）

### 時程

以每週約 15 小時計。「預估」是粗估，沒有依據實際經驗校正；
請在「實際」欄記下花的時數，做完兩三個階段後再回頭調整後面的預估。

| 週 | 日期 | 週 | 日期 |
|---|---|---|---|
| W1 | 10/5–10/11 | W6 | 11/9–11/15 |
| W2 | 10/12–10/18 | W7 | 11/16–11/22 |
| W3 | 10/19–10/25 | W8 | 11/23–11/29 |
| W4 | 10/26–11/1 | W9 | 11/30–12/6 |
| W5 | 11/2–11/8 | W10 | 12/7– |

找工作的節奏：做完階段 3（約 W5）就具備 DT、probe、IRQ、IIO 的實作經驗，可以開始投履歷；
後面的階段（並行、字元裝置）可以邊面試邊做，剛好補上面試中被問倒的題目。

每個階段開始時，先讀 `docs/lessons/` 下該階段的講解檔案，再讀下面列的材料。

閱讀材料的路徑以專案使用的 kernel 原始碼為準；不存在的話再找替代。
共通參考：Bootlin「Linux kernel and driver development」免費講義（https://bootlin.com/training/kernel/ ）。
LDD3（Linux Device Drivers, 3rd ed.）觀念仍有用，但 API 已過時，程式碼不要照抄。

---

## 階段 0：環境與 kernel 建置

分工：環境腳本由 Claude 寫並逐步講解；hello module 由你寫。

**學完要能回答**
- Kconfig／`.config` 是什麼？`=y` 和 `=m` 差在哪？
- cross compile 時 `ARCH`、`CROSS_COMPILE` 各做什麼？
- kernel 開機後怎麼找到並執行第一個 user space 程式（initramfs、`/init`）？
- QEMU 的 `virt` 機器怎麼把硬體描述交給 kernel（DTB）？
- out-of-tree module 怎麼對著某個 kernel 樹編譯？為什麼版本必須對上？

**閱讀**
- `Documentation/kbuild/modules.rst`
- `Documentation/filesystems/ramfs-rootfs-initramfs.rst`

**實作**
- [ ] 理解環境腳本的每一步（能自己講一遍）
- [ ] 寫 hello module：`module_init`／`module_exit`、`pr_info`、`MODULE_LICENSE`
- [ ] 加一個 module parameter，載入時傳值

**驗收**
- [ ] QEMU 開機進 shell
- [ ] `insmod`／`rmmod` hello module，dmesg 有訊息，`modinfo` 看得到參數

---

## 階段 1：Device model、device tree、probe/remove

**學完要能回答**
- bus、device、driver 三者關係？driver 和 device 什麼時候、怎麼配對（match）？
- DT 節點怎麼變成 `platform_device`？`compatible` 怎麼對到你的 driver？
- probe 失敗時資源怎麼清？`devm_*` 解決什麼問題、釋放順序是什麼？
- `-EPROBE_DEFER` 是什麼情況？

**閱讀**
- `Documentation/driver-api/driver-model/`（overview、binding、platform）
- `Documentation/devicetree/usage-model.rst`
- `Documentation/driver-api/driver-model/devres.rst`

**實作**
- [ ] 在 DTB 加上自己的節點（自訂 `compatible` 與幾個屬性）
- [ ] `platform_driver` + `of_match_table`，probe 時讀 DT 屬性
- [ ] 錯誤路徑用 `dev_err_probe`

**驗收**
- [ ] dmesg 有 probe 訊息，`/sys/bus/platform/` 看得到裝置與 driver 綁定
- [ ] `insmod`／`rmmod` 連續 100 次，KASAN 沒有報錯
- [ ] 手動 unbind／bind（sysfs）正常

---

## 階段 2：Regmap、IIO sysfs、mutex

**學完要能回答**
- IIO subsystem 解決什麼問題？channel、`read_raw`、`scale` 是什麼？
- 從 user space `cat` 一個 sysfs 檔，到你的 `read_raw` 被呼叫，中間經過什麼？
- 為什麼這裡用 mutex 而不是 spinlock？（提示：讀暫存器會 sleep）
- regmap 帶來什麼好處？為什麼之後換成 I2C 只要改一層？

**閱讀**
- `Documentation/driver-api/iio/core.rst`
- `drivers/iio/dummy/`（in-tree 範例 driver）
- `include/linux/regmap.h`
- `Documentation/locking/mutex-design.rst`

**實作**
- [ ] 用 regmap 自訂 `reg_read`／`reg_write` 模擬 sensor 暫存器（`usleep_range` 模擬 bus 延遲）
- [ ] IIO channels + `read_raw`／`write_raw`（數值、scale、取樣率）
- [ ] 用 mutex 保護「多個暫存器要一起讀寫」的區段

**驗收**
- [ ] `/sys/bus/iio/devices/iio:deviceX/` 下的檔案可讀寫，數值合理
- [ ] 兩個 shell 同時讀寫不會讀到不一致的資料

---

## 階段 3：中斷 — threaded IRQ、IIO trigger／buffer

**學完要能回答**
- hard IRQ handler 和 threaded handler 各在什麼 context？各自能做、不能做什麼？
- 為什麼讀 I2C 必須放在 threaded handler？`IRQF_ONESHOT` 的作用？
- edge 和 level trigger 差別？
- 什麼時候需要 `spin_lock_irqsave`？跟 `spin_lock` 差在哪？
- completion 是什麼？跟 wait queue、semaphore 的差別？

**閱讀**
- `Documentation/core-api/genericirq.rst`
- `Documentation/driver-api/iio/triggers.rst`、`buffers.rst`、`triggered-buffers.rst`
- `Documentation/admin-guide/gpio/gpio-sim.rst`
- `Documentation/kernel-hacking/locking.rst`（Unreliable Guide To Locking）

**實作**
- [ ] DT 用 `interrupts-extended` 指向 gpio-sim 的一條線
- [ ] `devm_request_threaded_irq`：hard IRQ 記時間戳，thread 讀資料
- [ ] IIO trigger + triggered buffer
- [ ] 單次讀取（sysfs）用 completion 等「資料就緒」中斷

**驗收**
- [ ] 從 user space 拉動 gpio-sim 線 → 中斷觸發 → buffer 讀到資料（含時間戳）
- [ ] `/proc/interrupts` 看得到你的 IRQ 與計數

---

## 階段 4：並行與除錯工具

**學完要能回答**
- race condition 怎麼發生？舉出你 driver 裡可能出現的 race。
- remove 時中斷還在跑會怎樣？`devm` 釋放順序如何影響這件事？
- lockdep 怎麼偵測 deadlock？為什麼「還沒真的卡住」就能報？
- `DEBUG_ATOMIC_SLEEP` 抓的是什麼錯誤？

**閱讀**
- `Documentation/locking/lockdep-design.rst`
- `Documentation/locking/spinlocks.rst`
- `Documentation/dev-tools/kasan.rst`

**實作**
- [ ] 壓力測試腳本：多個 reader、同時改設定、讀取中途 `rmmod`、中斷狂打
- [ ] 實驗 branch（不合併）：故意放錯誤，看工具能不能抓到
  - [ ] IRQ context 裡拿 mutex
  - [ ] 兩把鎖順序相反（AB-BA）
  - [ ] remove 後還被中斷存取（use-after-free）

**驗收**
- [ ] 正式程式碼跑壓力測試，lockdep／KASAN 沒有報錯
- [ ] 每個故意的錯誤都能讀懂工具的報告，說出原因

---

## 階段 5：字元裝置 — user/kernel 邊界

另外寫一個小 module（不混進 IIO driver）。

**學完要能回答**
- user space 呼叫 `read()` 到 driver 的 `.read`，中間發生什麼（system call、VFS）？
- 為什麼不能直接存取 user 指標？`copy_to_user` 做了什麼檢查？
- blocking 與 non-blocking（`O_NONBLOCK`）read 怎麼實作？
- `poll`／`select` 在 driver 端怎麼實作？
- ioctl 的編號怎麼定（`_IOR`／`_IOW`）？
- mutex 和 semaphore 差在哪？什麼時候還會用 semaphore？

**閱讀**
- `include/linux/miscdevice.h`、`include/linux/fs.h`（`struct file_operations`）
- `Documentation/userspace-api/ioctl/ioctl-number.rst`
- LDD3 第 3、6 章（觀念）

**實作**
- [ ] misc device + `file_operations`：`read`、`write`、`unlocked_ioctl`、`poll`
- [ ] wait queue 實作 blocking read
- [ ] user space 測試程式（含 `poll` 與 `O_NONBLOCK`）

**驗收**
- [ ] 測試程式驗證 blocking／non-blocking／poll 行為正確
- [ ] 多個 process 同時開啟、讀寫不出錯

---

## 階段 6：文件與模擬面試

**實作**
- [ ] DT binding YAML，`make dt_binding_check` 通過
- [ ] 設計文件：資料流（硬體 → IRQ → buffer → user space）、鎖的設計與理由
- [ ] 用自己的話寫一段 3 分鐘的專案介紹
- [ ] 模擬面試一次（Claude 當面試官）

---

## 階段 7：（之後）搬到樹莓派 + 真實 sensor

- 買 MPU6050（有 INT 腳）或 BME280（沒有 INT 腳）
- regmap 改成 regmap-i2c，DT overlay 改到 Pi 的 I2C bus 與 GPIO
- 確認不和 in-tree driver（`inv_mpu6050`／`bmp280`）衝突
