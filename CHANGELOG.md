# Changelog

本仓库为第三方二改版本，版本号沿用上游 AlwaysStrong 的 `v1.0.4` 并加 `-omk` 后缀。

## v1.0.4-omk-r5 — 2026-09-29

修正 r4 实验性开关的默认状态与说明，并修掉开关开启时 PIF 补丁日期写不进去的缺陷。

### 修复

- **开关开启时 Play Integrity 三项全红**：`sync_patch.sh` 写 pif 的 `*.security_patch`
  用的是裸 `toybox sed -i`，部分 ROM 上这条编辑静默不生效。默认模式下 `EFF` 恰好等于
  指纹自带日期，`migrate.sh` 早已写过同一个值，所以文件看起来是对的；一旦「统一日期」
  把 `EFF` 抬到 ROM 的真实补丁，pif 仍停在指纹日期，而 `security_patch.txt` 与系统属性
  已经跟着走了 —— 日志里就是这种三处不一致（`security_patch.txt` 2026-09-01、
  `pif *.security_patch` 2026-08-05、属性 2026-09-01），三项判定因此全红。
  - 改为优先使用 busybox `sed`，写完立刻回读校验，读回不等于目标值就整文件重建
    （`grep -v` 过滤旧行 + 追加新行 + `cat` 回写同一 inode，保留权限与 SELinux 上下文），
    不再依赖某个 sed 实现是否支持就地编辑。
- **开关默认状态**：r4 里该开关是「开（默认）」，与用户预期相反。现在默认关闭 ——
  全新安装与升级都等同 r2fix 的行为：三处一律用指纹自带日期。标志文件也从
  `spoof_patch_props`（r4 的「严格」语义）改名 `unified_patch_date`（现在的「统一」语义），
  并在 `sync_patch.sh` 里清掉可能残留的旧标志，避免升级继承一个已失效的状态。

### 变更

- `webroot/index.html`：「统一日期策略（测试）」的说明改为明确指向
  **Tampered Attestation Key 26** 这一项，并标注关闭为默认值；en / tr / zh 三份文案同步。
- `collect_logs.sh`：`date mode:` 一行改为按 `unified_patch_date` 判断，直接打印
  「strict fingerprint, own date (default)」或「unified, newest of fingerprint/ROM (experimental toggle ON)」。
- `module.prop`：`version=v1.0.4-omk-r5`、`versionCode=10405`。

## v1.0.4-omk-r4 — 2026-09-29

把 r3 的日期策略做成 WebUI 上的实验性开关，供排查「Tampered Attestation Key」用。

### 新增

- `webroot/index.html`：Advanced 页新增「统一日期策略（测试）」一行（琥珀色警示样式 +
  `测试` 角标），位于「Spoof security patch」下方：
  - **开（默认）** = r3 逻辑：三处日期取「指纹补丁」与「ROM 真实补丁」中较新的一个；
  - **关** = 严格使用指纹自带日期，忽略 ROM 更新的真实补丁 —— 即 r3 之前的行为。
  - 切换后立即调用 `sync_patch.sh boot` 生效，无需重启。
  - 行内注明这是实验性排查项，并明确「Tampered Attestation Key 通常与 keybox 有关，
    本项未必有效」。
  - 文案进 en / tr / zh，其余语言回退英文。
- 底层复用 `sync_patch.sh` 既有的 `spoof_patch_props` 强制分支（`FORCE=1`），
  WebUI 开关关闭时创建该文件，打开时删除。

### 变更

- `collect_logs.sh`：日期一致性段新增 `date mode:` 一行，打印当前用的是统一日期还是
  严格指纹日期。
- `sync_patch.sh`：为 `FORCE` 分支补充说明注释（它是 WebUI 该开关的落地）。
- `module.prop`：`version=v1.0.4-omk-r4`、`versionCode=10404`。

### 说明

`Tampered Attestation Key` 指证明密钥被判定为篡改，绝大多数情况是 keybox 被 Google
判定为共享滥用或证书链不合法，与安全补丁日期无关。本开关是给用户做 A/B 排查用的
逃生口，不是该报错的修复项。

## v1.0.4-omk-r3 — 2026-09-29

修复安全补丁日期「被自动改写」与「三处日期互相不一致」两个问题。

### 修复

- **三处日期统一为一个值**：安全补丁日期此前分散在三处 —— 系统属性
  `ro.build.version.security_patch`、`/data/adb/tricky_store/security_patch.txt`
  （引擎写进硬件证明的 osPatchLevel）、以及 pif 的 `*.security_patch`（PIF 的
  zygisk 报给 GMS 的日期）。OhMyKeymint 的 `config.toml` 补丁字段保持 `auto`，
  所以引擎证明最终也跟随系统属性。三者必须一致，否则证明校验会报
  「OS patch 与 osPatchLevel 不符」。
  - `sync_patch.sh`：改为先算出一个统一日期 `EFF`，三处全部由它写入。
    - 默认：取指纹的 `SECURITY_PATCH`，但不早于 ROM 自身补丁 —— 即
      「只前进不后退」，OTA 跑在指纹前面时保留更新的真实日期。
    - 关闭补丁伪装（`no_spoof_patch_props`）：三处一律使用 ROM 真实日期，
      不再出现「属性回到真实、另外两处还在伪装」的错位。
  - `post-fs-data.sh`：在任何地方改写属性之前，先把 ROM 真实补丁记录到
    `/data/adb/tricky_store/.rom_security_patch`（每次开机刷新，自动跟随 OTA），
    供上面的「下限」与「真实日期」使用。
- **每小时刷新只改一半**：`service.sh` 的小时任务此前以非 boot 模式调用
  `sync_patch.sh`，只更新 `security_patch.txt`，系统属性要等下次重启才跟上，
  期间就会出现属性与证明日期不一致。现在小时任务同样以 boot 模式运行，
  属性随指纹一起重钉；`sync_patch.sh` 幂等，未变动的小时是空操作。

### 变更

- `webroot/index.html`：`spp`（Spoof security patch）开关说明改为「三处日期统一
  为一个值，关闭时三处都使用 ROM 真实日期」；切换时立即生效（开启与关闭都会
  立刻调用 `sync_patch.sh boot`），不再需要重启才生效。
- `collect_logs.sh`：新增「Security patch consistency」段，打印开关状态、
  ROM 真实日期、`security_patch.txt`、pif `*.security_patch` 与系统属性，
  不一致时直接给出 WARN。
- `uninstall.sh`：清理 `.rom_security_patch` 缓存。
- `module.prop`：`version=v1.0.4-omk-r3`、`versionCode=10403`。

## v1.0.4-omk-r2fix — 2026-09-28

在保持一加等机型三项全红修复的前提下，让三个冲突开关恢复可开启，改为在 WebUI 里
说明开启后果。

### 变更

- **`spoofProvider` / `spoofSignature` / `spoofVendingSdk` 不再被强制锁定**：
  r2 里这三个键被引擎忽略、WebUI 开关置灰，用户无法开启。本版改为
  「升级时一次性清理 + 之后尊重用户选择」：
  - `engine.sh`：移除 `engine_locked_keys()`；新增 `engine_migrate_spoof_conf()`，
    在 `engine_enforce_spoof()` 首次运行时，把从旧的非 OMK 安装继承下来的这三个键
    从 `spoof.conf` 中删除一次（标记 `/data/adb/tricky_store/.spoof_keys_purged`，
    该目录跨模块更新保留），之后 `spoof.conf` 里的取值一律生效。
    这样升级不会再继承一份让三项全红的配置，而用户明确开启时仍然可用。
  - `webroot/index.html`：三个开关恢复为可点；行内加琥珀色警示说明，注明「开启后
    PlayIntegrityFork 会伪造证明引擎正在应答的 keystore 调用，两者冲突会导致
    Play Integrity 三项判定全部变红」，开启时再弹一条警示 toast。
    `spoofwarn` / `spoofwarn_toast` / `spoofwarn_tag` 已加入 en / tr / zh 文案，
    其余语言回退英文。
- `collect_logs.sh`：把「键已被锁定、这行无效」的提示改为「该键为开启状态，会与
  证明引擎冲突导致三项全红」的告警，并报告一次性清理是否已执行。
- `module.prop`：`version=v1.0.4-omk-r2fix`、`versionCode=10402`。

## v1.0.4-omk-r2 — 2026-09-28

修复一加等机型上 Play Integrity 三项全红的问题。

### 修复

- **PIF 与 OMK 争抢 keystore 导致三项全红**：`spoofProvider` / `spoofSignature` /
  `spoofVendingSdk` 三个标志会让 PlayIntegrityFork 的 zygisk 去拦截 OhMyKeymint
  正在应答的同一批 keystore 调用，两边互相打架，三项判定全部变红。
  从旧的非 OMK 安装带过来的 `spoof.conf` 是最常见的触发来源。
  - `engine.sh`：新增 `engine_locked_keys()`，`engine_spoof_val()` 对这三个键
    一律取默认值（均为 0），忽略 `spoof.conf` 里的任何覆盖；其余标志仍可由
    WebUI 覆盖。更新后首次开机 `action.sh` 会自动把三键强制写回 0。
  - `webroot/index.html`：Advanced 页把这三个开关渲染为「locked」并置灰禁用，
    防止再次写入冲突值。

### 变更

- `collect_logs.sh`：新增 `spoof.conf` 内容与「实际生效的 spoof 标志」诊断，
  并对被锁定但仍留在 `spoof.conf` 里的键给出提示，避免误判。
- `module.prop`：`version=v1.0.4-omk-r2`、`versionCode=10401`。

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
- `conflict_scan.sh`：检测到独立 OhMyKeymint 模块时禁用本模块。
- SELinux 规则取「AlwaysStrong 原规则 ∪ 上游 OMK 规则」，未引入 TCP 调试面。

### 保留

- PlayIntegrityFork v18 及其适配层 `engine.sh`。
- `asfetch` / `aswatcher` 原生指纹抓取与自动刷新。
- WebUI 与 Action 按钮。
- keybox 抢救逻辑：覆盖引擎前备份到 `/data/adb/omk/guard.keybox.xml`，
  恢复后写回；仅在 keybox 与内置版本不同时写回。

### 已知限制

- 仅支持 **arm64-v8a**（OhMyKeymint 上游只提供 arm64-v8a 载荷）。
- 不能与独立 OhMyKeymint 模块同时安装。
- 从其他 OMK 引擎切换过来的**首次开机**，旧密钥 blob 可能无法解密，
  自愈逻辑会重建私有存储；此时旧应用密钥失效属预期行为。
