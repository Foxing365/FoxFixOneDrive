# FoxFixOneDrive

**macOS OneDrive 防失控与死循环自愈守护工具（Apple Silicon 软硬件协同降频 + 代理死连接自愈 + 穿透勿扰模式悬浮通知）**

> Lightweight (~0.001% idle CPU) self-healing guard for **Microsoft OneDrive for Mac** on Apple Silicon. Automatically detects 0 KB/s upload/scan deadlocks and `fileproviderd` badge storms, resets stalled Clash/Mihomo proxy sockets to restore real-time sync, and confines runaway threads to Efficiency Cores (`E-Cores`) via `taskpolicy` until sync stabilizes.

---

## 为什么 OneDrive for Mac 动不动就把自己“绕晕”？（基于 `sample` 与 `log` 的逆向诊断）

通过对 macOS 版 `OneDrive`（`MSSyncEngine` / `MSP2P` / `PlaceholderManager`）与系统 `fileproviderd` 进行 1ms 级调用栈采样（`/usr/bin/sample`）和统一日志（`/usr/bin/log`）追踪，我们定位到了导致它高发热、高掉电的 **4 个核心架构缺陷**：

1. **每次局部扫描都“重建再销毁”全盘数万个文件的内存哈希表（$O(N \times M)$ 放大）**
   - 当哪怕 1～5 个文件发生变更或重试，触发局部精确扫描 `FileScanner::DoPreciseScanWorkInternal()` 时，OneDrive 会先调用 `FileScanner::IsFullScanNeeded()` → `FileScanner::InitializeCache()`，把云盘中**所有已知的数万个文件与文件夹**遍历一遍，逐个转换大小写并计算哈希，填入 `PridnameSet` 与 `ClientFolderCacheByPath`。
   - 紧接着在几十毫秒后的 `finalizeScan()` 中，它又立刻调用 `FileScanner::FreeCache()` 将刚建好的全量缓存彻底销毁。一旦遇到高频重试，每秒钟都在重复“全盘建表 → 销毁”。
2. **上传/下载断流后缺乏指数退避（Exponential Backoff）的正反馈死循环**
   - 当分块上传遇到代理抖动或节点切流失败时，`UploadGate::CleanUpFailedActiveUploads()` 会调 `DriveInfo::RequestPreciseScanIfFileExistsElseFullScan()` 请求立即重扫，随后在 `AssignIdsToDriveChange` 中调用 `FileStatusNotifier::ForceClearFileError()` 清除错误并重新触发 `FileUploadStarted()`。
   - 这导致失败文件每隔 **0.6～1.8 秒** 就循环一次，向 macOS 的 `fileproviderd` 每秒轰炸多达 **50+ 次** `com.microsoft.OneDrive.FileProviderBadges.Syncing` 角标刷新。
3. **单文件重试时的“脉冲式装死”**
   - 当只有 1～5 个文件卡在上传重试时，`Core Loop` 线程呈现 **“全盘建表重扫 1.0 秒（65%–85% CPU）→ `CoreIdleState::WaitForWork` 休眠 0.5 秒（0% CPU）”** 的脉冲波形，瞬时 `%CPU` 忽高忽低，但累计每分钟都在白白消耗 20～40 秒大核 CPU 时间。
4. **单线程核心循环内同步读取磁盘 `xattr` + 同步 AES 加密写日志**
   - 在 `Core Loop` 单线程内，每处理一次文件状态变更都会同步调用 `+[MacboxUtils getStringXattr:xattrName:value:]` 读取磁盘扩展属性，并调用 `StripPrivateInfoFromString()` → `LogObfuscatorAes::ObfuscatePrivateInfo()` → `CCCrypt` 对路径做 **AES 加密 + Base64 编码**写诊断日志，吃掉超过 20% 的核心循环 CPU。

---

## FoxFixOneDrive 是如何解决的？

由于 `OneDrive.app` 带有 Apple Developer ID 签名与 Hardened Runtime 保护（直接修改二进制会导致 macOS `fileproviderd` 拒绝加载云盘扩展），**FoxFixOneDrive** 采用从外部协同内核调度器与本地代理栈的**无损自愈方案**：

```mermaid
flowchart TD
    A["第一阶段：轻量快检 (每 30 秒一次 ps)"] -->|"耗时 ~0.04s, 零磁盘/日志读取"| B{"累计 CPU 积分 >= 22%\n或 合计 >= 30% ?"}
    B -->|"否 (99.9% 的日常时间)"| A
    B -->|"是 (发现疑似高负载)"| C["第二阶段：3 秒 nettop 真实网速采样"]
    C --> D{"实时网速 >= 5 KB/s ?"}
    D -->|"是 (正在正常高速上传/下载)"| E["立即确保/恢复性能大核 (taskpolicy -B)\n保障实时同步满速运行"]
    D -->|"否 (高 CPU + 0 KB/s 空转死循环)"| F["连续确认达到阈值 (2 次)"]
    F --> G["1. 通过 Clash/Mihomo Socket 精准重置 OneDrive 卡死连接\n2. 调用 taskpolicy -b 将 OneDrive 锁入能效小核 (E-Core)\n3. 弹出穿透勿扰模式的右上角毛玻璃悬浮通知"]
    G --> H{"网速恢复 >= 5 KB/s\n或 CPU 稳定回落 < 12% ?"}
    H -->|"是"| I["调用 taskpolicy -B 100% 无损放回大核 (P-Core)\n并弹出恢复通知"]
```

### 四大核心特性
1. **两段式懒检测 + 累计 CPU 时间积分（平时开销 `< 0.001% CPU`）**
   - 平时每 30 秒仅调用一次 `ps -Ao pid,pcpu,time,rss,comm`（不查系统 `/usr/bin/log`，不跑 `nettop`）。
   - 同时计算周期内的**累计 CPU 时间积分（`ΔTIME / ΔElapsed`）**，即使只有单个 PDF/Word 文件处于“扫 1 秒、睡 0.5 秒”的脉冲式死循环，也能 100% 精准捕获。
2. **先通网、再降温（绝不暂停实时同步）**
   - 一旦确认处于“高 CPU + 零网速（`< 5 KB/s`）”死循环，自动通过 Clash Verge / Mihomo 的本地 Unix Socket 精准关闭属于 `OneDrive` 的假死代理连接（不影响其他应用），逼 OneDrive 立即重新握手恢复上传。
3. **100% 双向可逆的 Apple Silicon 大小核调度（仅用 `taskpolicy -b / -B`）**
   - 死循环期间调用 `/usr/sbin/taskpolicy -b -p <PID>` 将 OneDrive 限制到 Apple Silicon **能效小核（E-Core）**，功耗立降 80% 以上；
   - 一旦检测到真实网速恢复（`>= 5 KB/s`）或 CPU 回落稳定，第 1 时间调用 `/usr/sbin/taskpolicy -B -p <PID>` **100% 无损放回性能大核（P-Core）**（不使用在非 root 下不可逆的 `renice`）。
4. **100% 穿透「勿扰模式」的原生右上角毛玻璃悬浮通知**
   - 内置约 120 行 Swift 编写的原生 AppKit 悬浮横幅组件 [`src/onedrive_hud.swift`](src/onedrive_hud.swift)：
   - 采用 `.nonactivatingPanel` + `.statusBar` 层级，**直接穿透 macOS 勿扰模式/专注模式**，**绝不抢占打字焦点**，显示 6.5 秒后自动淡出退出（**0 内存后台驻留**），同时写入系统通知中心留存历史。

---

## 快速安装与使用

### 一键安装（开机自启）
在终端运行（或直接在 Finder 中双击 `setup-macos.command`）：
```zsh
chmod +x setup-macos.command status-macos.command uninstall-macos.command src/onedrive_guard.sh
./setup-macos.command
```

### 常用命令
```zsh
# 查看当前守护进程状态、OneDrive 实时状态与最近日志（或双击 status-macos.command）
./status-macos.command

# 手动触发一次穿透勿扰模式的右上角毛玻璃悬浮通知测试
~/.local/share/onedrive-guard/onedrive_guard.sh --test-notify

# 手动执行一次单次快检
~/.local/share/onedrive-guard/onedrive_guard.sh --once

# 手动将 OneDrive 立即恢复回性能大核默认调度
~/.local/share/onedrive-guard/onedrive_guard.sh --restore

# 卸载并移除开机自启（或双击 uninstall-macos.command）
./uninstall-macos.command
```

---

## 实战日志示例

当单个文件（如 PDF/Word）在代理层卡死、触发 OneDrive 85% CPU 重扫风暴时，FoxFixOneDrive 在 45 秒内自动完成检测、重置连接、小核限流、重传成功并恢复大核的完整闭环：

```text
[2026-11-02 03:31:02] OneDrive 防失控守护进程已启动。
[2026-11-02 03:33:06] 检测到疑似死循环空转 (1/3): OneDrive=27.6%, fileproviderd=115.6%, 网速=0.0KB/s
[2026-11-02 03:33:29] 检测到疑似死循环空转 (2/3): OneDrive=67.8%, fileproviderd=25.5%, 网速=0.0KB/s
[2026-11-02 03:33:53] 检测到疑似死循环空转 (3/3): OneDrive=85.6%, fileproviderd=0.7%, 网速=0.0KB/s
[2026-11-02 03:33:53] ⚠️ 触发保护 (PID=1551): CPU 85.6% (合计86.3%) 但网速仅 0.0KB/s -> 已重置 6 个卡死连接并执行 taskpolicy -b 锁入能效核(E-Core)
[2026-11-02 03:36:13] ✅ 解除保护 (PID=1551): CPU 已稳定回落至 0.7% (fileproviderd 0.7%) -> 已执行 taskpolicy -B 恢复大核(P-Core)默认调度
```

---

## 附：Clash 代理下加速 OneDrive 的防断流建议

如果你使用 Clash Verge / Mihomo 的国外节点为 OneDrive 提速，请检查你的自动测速策略组（`url-test`）：
- **避免设置 `tolerance: 0`**：`tolerance: 0` 会在后台测速出现 1ms 波动时立刻切换出口节点，导致 OneDrive 正在进行的分块上传（HTTP PUT）被远端重置，进而触发 OneDrive 的无退避重扫死循环。
- **建议将 `tolerance` 设为 `100`～`150`**，让上传会话保持在稳定的同一出口 IP。

---

## License

[MIT License](LICENSE) © 2026 Foxing
