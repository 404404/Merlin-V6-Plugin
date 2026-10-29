# Merlin-V6-Plugin

面向华硕 Merlin / KoolShare 软件中心的插件维护仓库，包含 **IPv6管理** 与 **EasyTier**。两个插件分别在独立分支维护，默认 `Main` 提供项目导航与正式版下载入口。

## 插件与维护分支

| 插件 | 用途 | 正式版本 | 源码与使用文档 |
| --- | --- | --- | --- |
| IPv6管理 | AP模式IPv6修复：诊断 br0 的 SLAAC 参数、地址、默认路由及连通性，支持手动修复与可选自动任务 | [v0.1.0](https://github.com/404404/Merlin-V6-Plugin/releases/tag/apipv6-v0.1.0) | [IPv6-Fix-In-AP-Mode / README](https://github.com/404404/Merlin-V6-Plugin/blob/IPv6-Fix-In-AP-Mode/README.md) |
| EasyTier | AP 模式自启动、服务管理、只读节点信息与安全的核心版本识别 | [v1.1.0](https://github.com/404404/Merlin-V6-Plugin/releases/tag/plugin-v1.1.0) | [EasyTier-Merlin / README](https://github.com/404404/Merlin-V6-Plugin/blob/EasyTier-Merlin/README.md) |

两个插件可以按需分别安装。IPv6管理只处理 AP 自身的 br0 IPv6 客户端参数；EasyTier 的自启动在 IPv4 就绪后即可继续，不要求等待 IPv6。具体依赖、配置与故障处理见各分支 README。

## 正式版下载

请使用下面对应插件、对应平台的离线安装包。RT-AX56U 使用 **HND** 包；其他设备应按 KoolShare 软件中心的平台选择，QCA 包不代表已完成所有 QCA 设备的实机验证。

| 插件 | HND 安装包 | QCA 安装包 | 校验文件 |
| --- | --- | --- | --- |
| IPv6管理 v0.1.0 | [IPv6-Manage_hnd.tar.gz](https://github.com/404404/Merlin-V6-Plugin/releases/download/apipv6-v0.1.0/IPv6-Manage_hnd.tar.gz) | [IPv6-Manage_qca.tar.gz](https://github.com/404404/Merlin-V6-Plugin/releases/download/apipv6-v0.1.0/IPv6-Manage_qca.tar.gz) | [SHA256SUMS](https://github.com/404404/Merlin-V6-Plugin/releases/download/apipv6-v0.1.0/SHA256SUMS) |
| EasyTier v1.1.0 | [easytier_hnd.tar.gz](https://github.com/404404/Merlin-V6-Plugin/releases/download/plugin-v1.1.0/easytier_hnd.tar.gz) | [easytier_qca.tar.gz](https://github.com/404404/Merlin-V6-Plugin/releases/download/plugin-v1.1.0/easytier_qca.tar.gz) | [SHA256SUMS](https://github.com/404404/Merlin-V6-Plugin/releases/download/plugin-v1.1.0/SHA256SUMS) |

1. 下载所需插件的平台包及同一 Release 下的 `SHA256SUMS`，在电脑上核对 SHA-256。
2. 在 KoolShare 软件中心通过“离线安装”上传 `.tar.gz` 安装包。GitHub 自动生成的 Source code 压缩包用于查看源码，不能作为软件中心安装包。
3. 安装后按 **Ctrl+F5** 刷新软件中心和插件页面，避免旧名称、图标或页面缓存。

本仓库发布两种插件，`releases/latest` 只指向仓库当前标为 Latest 的一个 Release。请按上表中的插件专属链接下载，避免混淆安装包。需要回滚时，使用对应分支 README 与安装日志中的备份命令。

## 使用与升级要点

- **IPv6管理**：显示名称为“IPv6管理”，描述为“AP模式IPv6修复”，安装包前缀为 `IPv6-Manage`，内部模块标识继续使用 `apipv6` 以兼容已有安装。新安装默认关闭自动任务，升级保留原开关与时间设置；安装本身不会修改网络参数。只有 `sw_mode=3` 且 `wlc_psta=0` 时允许修复。无法识别的旧 `V00apipv6.sh` 会保留并报告冲突，应先备份核对再处理。
- **EasyTier**：插件版本为 1.1.0，新安装包的官方核心构建基线为 v2.6.4。升级保留设备现有核心、配置、EasyTier DBUS 配置及运行进程；设备核心版本通过本机 RPC 或精确文件指纹识别，无法识别时显示“未知”。节点面板提供只读信息，详细字段与兼容性限制见分支文档。

## 已记录的实机反馈

测试设备为 **ASUS RT-AX56U / KoolShare Merlin / AP 模式 / ARMv7l**。

| 插件 | 用户已反馈的结果 | 尚需单独记录的范围 |
| --- | --- | --- |
| IPv6管理 | 2026-10-29 反馈安装运行、状态信息读取正常，并授权发布 v0.1.0 正式版 | 开机自动修复、断电冷启动、上游 RA 中断、旧脚本迁移及卸载/回滚；参见 [验收清单](https://github.com/404404/Merlin-V6-Plugin/blob/IPv6-Fix-In-AP-Mode/docs/AX56U-ACCEPTANCE.md) |
| EasyTier | 2026-10-28 反馈重启自启动正常；2026-10-29 确认功能、节点数据采集与软件中心官方图标正常，并授权发布 v1.1.0 正式版 | 断电冷启动、其他型号与固件；正式版移除页面额外图标后的显示效果仍需升级后确认 |

两个正式版本发布前均已通过各自 CI、打包与资产校验。CI 和已有设备反馈的覆盖范围不同，其他平台请按各分支的验证说明记录结果。

## 仓库维护方式

- `Main`：项目介绍、插件导航与正式版下载。
- `IPv6-Fix-In-AP-Mode`：IPv6管理源码、文档、测试与打包。
- `EasyTier-Merlin`：EasyTier 插件源码、文档、测试与打包。
- 插件在各自维护分支开发和发布，无需合并到 `Main`。IPv6管理使用 `apipv6-v*` 标签；EasyTier 使用 `plugin-v*` 标签。
- 下载以正式 Release 资产为准；Actions 工件有保留期限。旧测试 Release 可能被清理，Git 标签与提交历史继续保留用于追溯。
- EasyTier 插件源自 [mumuchen122-sudo/easytier-merlin](https://github.com/mumuchen122-sudo/easytier-merlin)，核心来自 [EasyTier 官方项目](https://github.com/EasyTier/EasyTier)。核心版本、图标来源及许可证说明见 EasyTier 分支 README。
