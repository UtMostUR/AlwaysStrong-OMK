# AlwaysStrong-OMK

**Unofficial AlwaysStrong build whose attestation engine is [OhMyKeymint](https://github.com/qwq233/OhMyKeymint) instead of TEESimulator-RS.**

把 [AlwaysStrong](https://github.com/evoker0/AlwaysStrong) 的硬件密钥证明引擎从 TEESimulator-RS
换成 OhMyKeymint，其余骨架（PlayIntegrityFork、原生指纹抓取、WebUI、Action 按钮）保持不变。
刷入即用，目标是让 Play Integrity 拿到 **STRONG**。

---

## ⚠️ 重要声明

- 本项目是**第三方非官方二改**，与 [evoker0/AlwaysStrong](https://github.com/evoker0/AlwaysStrong)、
  [qwq233/OhMyKeymint](https://github.com/qwq233/OhMyKeymint) 的作者**没有任何从属、赞助或背书关系**。
  仓库名中的 "OMK" 仅用于说明本构建所搭载的证明引擎。
- **禁止任何商业用途**（见 [LICENSE-OhMyKeymint.txt](LICENSE-OhMyKeymint.txt) 第 1 条）。
- 仅供**学习、研究与自用**。因使用本模块产生的任何后果由使用者自行承担。
- 请勿用于绕过任何你无权访问的服务，或任何违反当地法律法规的用途。

---

## 与上游 AlwaysStrong 的差异

| 项目 | 上游 AlwaysStrong v1.0.4 | 本仓库 |
|---|---|---|
| 证明引擎 | TEESimulator-RS v6.0.1-307 | **OhMyKeymint 1.2.0-preview-a1f3241** |
| 引擎适配层 | `attest/tee.sh` | `attest/omk.sh` |
| 引擎守护 | 无（引擎自管） | `omk-daemon` + `omk-injector` |
| 早期初始化 | 无 | `omk-early.sh`（post-fs-data 阶段） |
| 配置桥接 | 无 | `omk-sync.sh`（镜像到 `/data/adb/tricky_store`） |
| Play Integrity | PlayIntegrityFork v18 | PlayIntegrityFork v18（不变） |
| 指纹自动刷新 | asfetch + aswatcher | 不变 |
| WebUI / Action | 有 | 不变 |

### 本次二改新增的修复

1. **Android 17 / SDK 37 链接错误**
   keymint 二进制在部分 ROM 上因 `cannot locate symbol "_ZNSt3__113__hash_memoryEPKvm"`
   起不来。`omk-daemon` 调整了 `LD_LIBRARY_PATH`，把 APEX 运行时目录
   （`/apex/com.android.runtime/lib64`）排在 `/system/lib64`、`/vendor/lib64` 之前，
   优先加载与 keymint 匹配的 libc++。

2. **私有存储无法解密导致的无限重启**
   OMK 的 level-zero 密钥 blob 由 `config.toml` 中 `[crypto]` 的种子派生保护，
   引擎切换后种子变化会让旧 blob 解密失败，keymint 快速退出并被反复拉起。
   `omk-daemon` 增加了双门控自愈：**60 秒内非请求快速退出 ≥ 2 次** 且
   `keymint.log` 出现密钥材料失败签名（`failed to decrypt keyblob` /
   `failed to initialize boot-level key cache` 等）时，重建
   `/data/misc/keystore/omk/data`，并把重建前的日志留证为
   `logs/keymint.log.store-reset`。

3. **错过 RPC 窗口导致注入失败**
   `inject` 库注入 keystore2 后只有 10 秒连接 keymint 服务端，超时即失败且不再重试。
   `attest.sh` 新增 `attest_ensure_injection()`：通过 `rpc.sock` 时间戳与
   `injector.log` 中的 `failed to connect OMK RPC socket` 判定是否需要补注入，
   15 分钟冷却后自动重注入。

4. **keybox 保护**
   引擎覆盖/恢复流程中先把 keybox 抢救到 `/data/adb/omk/guard.keybox.xml`，
   模块恢复后写回 `/data/misc/keystore/omk/keybox.xml`；仅在 keybox 与内置版本
   不同时才写回，避免用内置 keybox 覆盖用户自定义的。

---

## 组件版本

| 组件 | 版本 | 上游 |
|---|---|---|
| OhMyKeymint | `1.2.0-preview-a1f3241` | [qwq233/OhMyKeymint](https://github.com/qwq233/OhMyKeymint/releases/tag/1.2.0-preview-a1f3241) |
| PlayIntegrityFork | `v18` | [osm0sis/PlayIntegrityFork](https://github.com/osm0sis/PlayIntegrityFork) |
| AlwaysStrong 骨架 | `v1.0.4` | [evoker0/AlwaysStrong](https://github.com/evoker0/AlwaysStrong) |
| asfetch / aswatcher | 随 AlwaysStrong v1.0.4 | 同上 |

> `1.3.5` 是第三方分支版本，**不是** OhMyKeymint 官方版本；本仓库使用官方
> `1.2.0-preview-a1f3241`。

---

## 环境要求

- **Root 方案**：Magisk / KernelSU / APatch（作者环境为 KernelSU）
- **ABI**：仅 **arm64-v8a**。OhMyKeymint 上游只提供 arm64-v8a 载荷，
  其他 ABI 上 `attest/omk.sh` 会直接中止安装。
- **Android**：建议 Android 13+；Android 17（SDK 37）已修复链接问题。

---

## ⛔ 冲突：不要与这些模块同时安装

| 冲突模块 | 原因 |
|---|---|
| 月虹隐藏模块自带的 OMK 守护模块（`yh_omk_guard`） | 两者会抢占同一个 keystore2 注入 |
| 独立的 OhMyKeymint 模块 | 同上，重复提供 keymint / inject |

本模块自带 `conflict_scan.sh`，检测到上述模块会禁用本模块。**请先卸载它们再刷入。**

---

## 安装

1. 在管理器里卸载已安装的「OhMyKeymint」独立模块与月虹的 OMK 守护模块，**重启一次**。
2. 刷入本仓库 Release 中的 `AlwaysStrong-<version>.zip`。
3. 重启设备。
4. 重启后点模块的 **Action** 按钮查看状态，或打开 WebUI 的 Advanced 页。

---

## 验证是否生效

```sh
# 1. keymint 是否在跑（应该有两个 pid：服务端 + 守护）
pidof keymint

# 2. OMK 的 RPC 套接字是否就绪
ls -l /data/misc/keystore/omk/rpc.sock

# 3. keystore2 是否被注入（应能看到 inject 库）
grep -i inject /proc/$(pidof keystore2)/maps

# 4. 信任配置是否生效
cat /data/adb/tricky_store/config.toml      # 关注 [trust] 段的 device_locked / verified_boot_state

# 5. 一键收集全部诊断
sh /data/adb/modules/tricky_store/collect_logs.sh
```

端到端验证建议用 **Key Attestation**（`io.github.vvb2060.keyattestation`）或
**Play Integrity API Checker**，目标为 `MEETS_STRONG_INTEGRITY`。

若第 5 步的日志里出现 `store was dropped and rebuilt this boot`，说明自愈逻辑
在本次开机触发过（通常发生在从其他 OMK 引擎切换过来的第一次开机），
旧密钥失效属预期，之后的新操作会恢复正常。

---

## 构建

本仓库只提交**脚本与源码**，两个上游载荷在构建时下载，不纳入版本库。

```sh
./build.sh                          # 下载 OhMyKeymint + PlayIntegrityFork 并打包
./build.sh --omk-file PATH          # 用本地 OhMyKeymint zip，跳过下载
./build.sh --pif-file PATH          # 用本地 PlayIntegrityFork zip，跳过下载
./build.sh --clean                  # 先清掉 build/ 与 out/
```

输出：`out/AlwaysStrong-<version>.zip`

依赖：`bash`、`unzip`、`zip`、`curl`（或 `wget`）。

---

## 目录结构

```
attest/omk.sh          OhMyKeymint 适配层，构建时被覆盖为模块内的 attest.sh
module/                模块本体（AlwaysStrong v1.0.4 骨架 + OMK 适配脚本）
  ├── omk-daemon       keymint 守护：库搜索路径、崩溃自愈、重启循环
  ├── omk-injector     注入器包装：等待 RPC、失败重试
  ├── omk-early.sh     post-fs-data 阶段：清理跨开机残留标记
  ├── omk-sync.sh      配置桥接：OMK 配置面 ←→ /data/adb/tricky_store
  ├── engine.sh        PlayIntegrityFork 适配层
  ├── service.sh       服务启动 / 监控 / 注入兜底
  └── webroot/         WebUI
native/                asfetch / aswatcher 源码与预编译产物
docs/ADVANCED.md       进阶说明与排障
build.sh               构建脚本
```

---

## 许可证

本仓库是合并作品，**整体以 AGPL-3.0-or-later 发布**。

| 部分 | 许可证 | 文件 |
|---|---|---|
| 合并作品（本仓库） | AGPL-3.0-or-later | [LICENSE](LICENSE) |
| AlwaysStrong（evoker0 等） | GPL-3.0 | [LICENSE-GPL-3.0.txt](LICENSE-GPL-3.0.txt) |
| PlayIntegrityFork（osm0sis） | GPL-3.0 | 同上 |
| OhMyKeymint（qwq233） | AGPL-3.0 + 附加条款 | [LICENSE-OhMyKeymint.txt](LICENSE-OhMyKeymint.txt) |

GPL-3.0 与 AGPL-3.0 兼容（AGPL §13），因此合并分发时整体适用 AGPL-3.0。
完整的第三方组件清单、修改声明与免责声明见 [NOTICE.md](NOTICE.md)。

---

## 致谢

- [qwq233/OhMyKeymint](https://github.com/qwq233/OhMyKeymint) — 证明引擎
- [evoker0/AlwaysStrong](https://github.com/evoker0/AlwaysStrong) — 模块骨架、原生指纹抓取、WebUI
- [osm0sis/PlayIntegrityFork](https://github.com/osm0sis/PlayIntegrityFork) — Play Integrity 修复
- 以及 AlwaysStrong 上游致谢中列出的 JingMatrix、Enginex0、KOWX712 等
