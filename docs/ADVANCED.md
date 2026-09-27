# AlwaysStrong-OMK — 进阶说明

本页面向想了解内部机制或自行排障的用户。普通用户看
[README](../README.md) 就够了。

---

## 1. 引擎架构

上游 AlwaysStrong 的证明引擎是可替换的：模块脚本不直接调用引擎，而是通过
一个适配层（`attest.sh`）。本仓库把适配层从 `attest/tee.sh`
（TEESimulator-RS）换成了 `attest/omk.sh`（OhMyKeymint）。

```
                 ┌──────────────────────────────┐
                 │  service.sh / customize.sh    │
                 │  （与上游完全一致的骨架）        │
                 └───────────────┬──────────────┘
                                 │ 调用
                 ┌───────────────▼──────────────┐
                 │  attest.sh  ← attest/omk.sh   │
                 │  安装 / 启动 / 状态 / 同步 / 兜底 │
                 └───────────────┬──────────────┘
                                 │
        ┌────────────────────────┼────────────────────────┐
        │                        │                        │
   omk-daemon             omk-injector              omk-sync.sh
   （keymint 服务端）        （注入 keystore2）         （配置桥接）
        │                        │                        │
   libs/arm64-v8a/keymint   libs/arm64-v8a/inject   /data/adb/tricky_store
```

### 各组件职责

| 文件 | 职责 |
|---|---|
| `attest.sh`（源：`attest/omk.sh`） | 引擎适配层。安装载荷、启动守护、状态检测、配置同步、注入兜底。 |
| `omk-daemon` | keymint 服务端的守护进程。设置运行环境（含库搜索路径），维护重启循环与崩溃自愈。 |
| `omk-injector` | 把 `inject` 库注入 keystore2 进程的包装脚本。 |
| `omk-early.sh` | `post-fs-data` 阶段执行，早于 keymint 启动，清理跨开机残留标记。 |
| `omk-sync.sh` | 把 OMK 的配置面镜像桥接到 `/data/adb/tricky_store`，让 WebUI / Action 看到同一份配置。 |

---

## 2. 关键路径

| 路径 | 说明 |
|---|---|
| `/data/adb/modules/tricky_store/` | 模块目录（`id` 仍为上游的 `tricky_store`） |
| `/data/adb/tricky_store/config.toml` | 信任配置（`[trust]` 段等） |
| `/data/adb/tricky_store/injector.toml` | 注入配置（`scoop` 列表等） |
| `/data/adb/tricky_store/spoof.conf` | WebUI Advanced 页写入的 spoof 覆盖项 |
| `/data/misc/keystore/omk/rpc.sock` | OMK 的 RPC 套接字，keymint 就绪后才存在 |
| `/data/misc/keystore/omk/data/` | OMK 私有存储（`keymaster.db` 等） |
| `/data/misc/keystore/omk/logs/keymint.log` | keymint 日志 |
| `/data/adb/omk/guard.keybox.xml` | 覆盖引擎前抢救出来的 keybox |

---

## 3. 启动时序

```
post-fs-data
  └── omk-early.sh           清理上次开机的 store-reset 标记
boot_completed 之前
  └── omk-daemon             启动 keymint 服务端（必须早于 keystore2）
  └── omk-injector           等待 rpc.sock，注入 keystore2（10 秒窗口）
boot_completed 之后
  └── service.sh             属性设置、指纹刷新、周期校验
  └── attest_ensure_injection()  注入看门狗
```

OMK 原生栈没有 Java 依赖，因此可以且必须在 `boot_completed` 之前启动，
以便抢在 keystore2 之前完成接管。

---

## 4. 排障

### 4.1 keymint 起不来

```sh
cat /data/misc/keystore/omk/logs/keymint.log
```

常见签名与含义：

| 日志签名 | 含义 | 处理 |
|---|---|---|
| `cannot locate symbol "_ZNSt3__113__hash_memoryEPKvm"` | 加载到了不匹配的 libc++ | 本仓库已通过 `LD_LIBRARY_PATH` 顺序修复；若仍出现，检查 ROM 的 APEX 运行时目录 |
| `failed to decrypt keyblob` | 旧密钥 blob 与当前 `[crypto]` 种子不匹配 | 自愈逻辑会重建私有存储 |
| `failed to initialize boot-level key cache` | 启动级密钥缓存初始化失败（通常是上一条的后果） | 同上 |

### 4.2 注入失败

```sh
cat /data/misc/keystore/omk/logs/injector.log
grep -i inject /proc/$(pidof keystore2)/maps
```

| 日志签名 | 含义 | 处理 |
|---|---|---|
| `failed to connect OMK RPC socket: Errno(-111)` | 注入时 keymint 服务端尚未就绪 | `attest_ensure_injection()` 会在冷却期后自动重注入 |
| `injector exited with code N` | 注入器异常退出 | 收集日志并核对 ABI 是否为 arm64-v8a |

### 4.3 一键诊断

```sh
sh /data/adb/modules/tricky_store/collect_logs.sh
```

输出会覆盖：模块版本与引擎、进程状态、`rpc.sock`、注入状态、`config.toml`
的 `[trust]` 段、私有存储列表、本次开机的 `crash_count`、以及是否触发过
存储重建（`store was dropped and rebuilt this boot`）。

### 4.4 存储重建

重建只在**双门控**同时满足时触发：

1. 60 秒内「非请求的快速退出」次数 ≥ 2；
2. `keymint.log` 中出现密钥材料失败签名。

重建时会把原日志改名为 `keymint.log.store-reset` 留证。
`omk-early.sh` 会在下次开机的 `post-fs-data` 阶段删除该标记，因此
**看到这个文件就代表本次开机确实重建过**。

从其他 OMK 引擎（例如独立 OhMyKeymint 模块）切换过来时，
首次开机会出现旧密钥失效的一次性报错，属预期。

---

## 5. 配置

`/data/adb/tricky_store/config.toml` 的 `[trust]` 段控制对外声称的设备状态，
例如 `device_locked`、`verified_boot_state`、`security_patch`、`os_version`。
WebUI 的 Advanced 页可以修改，保存后由 `omk-sync.sh` 桥接。

`spoof.conf` 里的 `key=value` 会覆盖 `engine.sh` 中的 STRONG 默认值。
默认值（PlayIntegrityFork 命名）：

```
spoofProvider=0 spoofVendingFinger=<自动> spoofBuild=1 spoofProps=1 spoofSignature=0 spoofVendingSdk=0
```

`spoofVendingFinger` 在真实 SDK ≤ 32（Android 10–12L）上默认关闭，
因为在这些版本上它会破坏而非帮助 Play Integrity。

---

## 6. 构建细节

`build.sh` 做四件事：

1. 把 `module/` 复制到 `build/module/`，并把 `attest/omk.sh` 覆盖为 `attest.sh`；
2. 把 `native/*/prebuilt/<abi>/` 下的 `asfetch`、`aswatcher` 放进 `bin/<abi>/`；
3. 下载并解包 OhMyKeymint，取出 `libs/arm64-v8a/{keymint,inject}`、
   `injector.toml`、`keybox.xml`；
4. 下载并解包 PlayIntegrityFork，取出 `classes.dex`、`zygisk/*.so` 与
   `autopif4.sh`、`killpi.sh`、`migrate.sh`、`common_setup.sh`、
   `example.pif.prop`、`app_replace_list.txt`。

任一必需文件缺失即 `die`，避免打出一个「指纹刷新静默失效」的包。

上游载荷不纳入版本库（见 `.gitignore`），以保证仓库体积可控，
同时避免再分发未经修改的第三方二进制时遗漏其许可证。

---

## 7. 上游同步

上游 AlwaysStrong 的引擎是可替换的，因此后续同步上游骨架时：

- `module/` 中与引擎无关的部分（`service.sh`、`action.sh`、`webroot/`、
  `pif_*.sh`、`native/`）可直接跟随上游；
- `attest/omk.sh` 与本仓库新增的 `omk-*.sh` 需要人工核对接口变化；
- 升级 OhMyKeymint 版本时改 `build.sh` 顶部的 `OMK_TAG` / `OMK_ASSET`，
  并确认 `libs/arm64-v8a/{keymint,inject}` 与 `injector.toml` 的布局未变。
