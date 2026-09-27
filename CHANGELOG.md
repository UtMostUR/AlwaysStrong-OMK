# Changelog

本仓库为第三方二改版本，版本号沿用上游 AlwaysStrong 的 `v1.0.4` 并加 `-omk` 后缀。
`versionCode` 为 `10400`。

## v1.0.4-omk — 2026-09-28

首个公开版本。基于 [AlwaysStrong v1.0.4](https://github.com/evoker0/AlwaysStrong) 骨架，
将证明引擎替换为 [OhMyKeymint 1.2.0-preview-a1f3241](https://github.com/qwq233/OhMyKeymint/releases/tag/1.2.0-preview-a1f3241)。

### 新增

- `attest/omk.sh`：OhMyKeymint 适配层，构建时覆盖为模块内的 `attest.sh`，
  负责引擎安装、启动、状态检测、配置同步与注入兜底。
- `omk-daemon`：keymint 守护进程。APEX 优先的库搜索顺序；启动崩溃自愈。
- `omk-injector`：注入器包装，等待 RPC 就绪后注入 keystore2。
- `omk-early.sh`：`post-fs-data` 阶段清理跨开机残留的 `keymint.log.store-reset` 标记。
- `omk-sync.sh`：把 OMK 配置面镜像桥接到 `/data/adb/tricky_store`。
- `collect_logs.sh`：新增私有存储列表、`crash_count`、store-reset 标记与触发原因诊断。

### 修复

- **Android 17 / SDK 37 链接失败**：keymint 报
  `cannot locate symbol "_ZNSt3__113__hash_memoryEPKvm"`。修正 `LD_LIBRARY_PATH`，
  将 `/apex/com.android.runtime/lib64` 置于 `/system/lib64`、`/vendor/lib64` 之前。
- **私有存储无法解密导致无限重启**：新增双门控自愈 —— 60 秒内非请求快速退出 ≥ 2 次，
  且 `keymint.log` 出现 `failed to decrypt keyblob` /
  `failed to initialize boot-level key cache` 等签名时，重建
  `/data/misc/keystore/omk/data`，并保留重建前日志为 `logs/keymint.log.store-reset`。
- **错过 RPC 窗口导致注入失败**：新增 `attest_ensure_injection()`，依据 `rpc.sock`
  时间戳与 `injector.log` 事件判定，15 分钟冷却后自动重注入。
- **`collect_logs.sh` 中 `ATTEST=?` 恒显示**：改为从 `attest.sh` 解析 `ATTEST` 变量。
- **store-reset 标记跨开机残留** 造成的诊断假阳性。

### 变更

- `module.prop`：`version=v1.0.4-omk`、`versionCode=10400`，
  描述改为 `OhMyKeymint + PlayIntegrityFork`，作者列表补充 James Clef、qwq233。
- 移除 `updateJson`（不提供在线更新）。
- `conflict_scan.sh`：检测到月虹 OMK 守护模块（`yh_omk_guard`）或独立 OhMyKeymint
  模块时禁用本模块。
- SELinux 规则取「AlwaysStrong 原规则 ∪ 上游 OMK 规则」，未引入 TCP 调试面。

### 保留

- PlayIntegrityFork v18 及其适配层 `engine.sh`。
- `asfetch` / `aswatcher` 原生指纹抓取与自动刷新。
- WebUI 与 Action 按钮。
- keybox 抢救逻辑：覆盖引擎前备份到 `/data/adb/omk/guard.keybox.xml`，
  恢复后写回；仅在 keybox 与内置版本不同时写回。

### 已知限制

- 仅支持 **arm64-v8a**（OhMyKeymint 上游只提供 arm64-v8a 载荷）。
- 不能与月虹 OMK 守护模块（`yh_omk_guard`）或独立 OhMyKeymint 模块同时安装。
- 从其他 OMK 引擎切换过来的**首次开机**，旧密钥 blob 可能无法解密，
  自愈逻辑会重建私有存储；此时旧应用密钥失效属预期行为。
