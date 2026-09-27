# NOTICE — 第三方组件、修改声明与免责声明

本仓库（`AlwaysStrong-OMK`）是第三方非官方二改项目。以下内容依据
GPL-3.0 §5 / AGPL-3.0 §5 的「标明修改」义务与 AGPL-3.0 §13 的组合作品要求编写。

---

## 1. 组件清单

| 组件 | 版本 | 著作权人 | 许可证 | 上游 |
|---|---|---|---|---|
| OhMyKeymint | `1.2.0-preview-a1f3241` | qwq233 及贡献者 | AGPL-3.0-or-later + 附加条款 | https://github.com/qwq233/OhMyKeymint |
| AlwaysStrong | `v1.0.4` | Evokerr (evoker0) 及贡献者 | GPL-3.0 | https://github.com/evoker0/AlwaysStrong |
| PlayIntegrityFork | `v18` | osm0sis 及贡献者 | GPL-3.0 | https://github.com/osm0sis/PlayIntegrityFork |

许可证全文：

- AGPL-3.0（本合并作品的许可证）：[`LICENSE`](LICENSE)
- GPL-3.0（AlwaysStrong / PlayIntegrityFork）：[`LICENSE-GPL-3.0.txt`](LICENSE-GPL-3.0.txt)
- OhMyKeymint 附加条款：[`LICENSE-OhMyKeymint.txt`](LICENSE-OhMyKeymint.txt)

---

## 2. 组合作品与许可证结论

- AlwaysStrong 与 PlayIntegrityFork 为 **GPL-3.0**；OhMyKeymint 为
  **AGPL-3.0-or-later** 并附有额外条款。
- GPL-3.0 与 AGPL-3.0 相互兼容；AGPL-3.0 §13 明确允许将 GPL-3.0 作品与
  AGPL-3.0 作品组合，组合后的整体必须按 AGPL-3.0 分发。
- 因此，**本仓库整体以 AGPL-3.0-or-later 发布**，并同时受 OhMyKeymint
  附加条款约束（商业使用禁止、不得暗示从属关系、名称使用限制等）。
- 若附加条款与 AGPL 冲突，就 OhMyKeymint 作者拥有完全著作权的部分而言，
  以附加条款为准。

### 使用者需要遵守的额外限制

1. **禁止商业用途。** 不得将本模块（或其任意部分、或以本模块为依赖的软件）
   用于任何以盈利为目的的用途，包括但不限于与其他资源、物品或服务捆绑销售。
2. **不得暗示从属关系。** 不得以任何方式暗示本二改版本与 OhMyKeymint 或
   AlwaysStrong 的官方作者存在从属、赞助或背书关系。
3. **名称使用限制。** 未经 OhMyKeymint 作者书面许可，不得超出合理使用范围
   使用其名称。本仓库名中的 "OMK" 仅作描述性说明用途。
4. **网络分发条款（AGPL §13）。** 若你修改本模块并通过网络向他人提供服务，
   必须向使用者提供对应的完整源码。

---

## 3. 修改声明

本仓库相对上游 AlwaysStrong v1.0.4 的修改（修改日期：2026-09-28）：

- 将证明引擎由 **TEESimulator-RS v6.0.1-307** 替换为
  **OhMyKeymint 1.2.0-preview-a1f3241**。
- 新增适配层 `attest/omk.sh`（构建时覆盖为模块内的 `attest.sh`），
  替代上游的 `attest/tee.sh`。
- 新增模块脚本：`omk-daemon`、`omk-injector`、`omk-early.sh`、`omk-sync.sh`。
- 修改 `service.sh`、`customize.sh`、`conflict_scan.sh`、`collect_logs.sh`、
  `module.prop` 等，接入 OhMyKeymint 的安装、启动、状态检测、同步与注入兜底。
- `omk-daemon`：调整 `LD_LIBRARY_PATH` 顺序以修复 Android 17 / SDK 37 上的
  libc++ 符号缺失；新增私有存储解密失败时的双门控自愈逻辑。
- `attest.sh`：新增 `attest_ensure_injection()` 注入看门狗。
- `collect_logs.sh`：修复 `ATTEST` 变量解析，补充私有存储与重建诊断。
- `omk-early.sh`：新增跨开机 `keymint.log.store-reset` 标记清理。
- 未引入上游 OhMyKeymint 的 TCP 调试面；SELinux 规则为「AlwaysStrong 原规则
  ∪ 上游 OMK 规则」。

上游文件的完整源码见各自仓库；本仓库中未修改的上游脚本保留其原始版权头。

---

## 4. 免责声明

- 本模块按「现状」提供，不附带任何明示或暗示的担保。
- 本模块会修改设备上的密钥证明行为，可能导致部分应用（尤其是银行、支付、
  风控类应用）出现异常，甚至影响设备保修状态。**请自行评估风险。**
- 请勿将本模块用于绕过你无权访问的服务，或任何违反当地法律法规的用途。
- 因使用本模块产生的一切后果，由使用者自行承担；本仓库作者不承担任何责任。

---

## 5. 无隶属关系声明

本项目为独立的第三方修改版本。**它不是** OhMyKeymint 或 AlwaysStrong 的官方
发行版，**未获得**其作者的赞助、授权或背书。所有上游项目的名称、标识与版权
归各自作者所有。
