# EasyTier KoolShare 插件

本仓库维护 KoolShare Merlin 软件中心插件，用于在华硕路由器上运行 EasyTier。

## 版本与核心

- 插件版本：**1.0.1**
- 新安装包的核心构建基线：**EasyTier 官方 v2.6.4**
- 核心来源：官方 [EasyTier v2.6.4 Release](https://github.com/EasyTier/EasyTier/releases/tag/v2.6.4)，构建前按仓库 Makefile 中固定的 SHA-256 校验。
- 插件升级会默认保留设备上现有的 easytier-core。插件版本、构建包核心版本和设备当前核心版本是不同信息。
- 设备当前核心版本不会通过运行 easytier-core --version 查询。若没有安全可靠的版本元数据，Web 页面显示“未知”；安装包内 v2.6.4 不代表设备现装核心版本。

当前 Phase 1 仅修复插件生命周期、自启动、升级保护和自动构建发布，不升级 EasyTier 核心，不开发节点状态面板或 IPv6 插件。

## 支持平台与架构

- KoolShare 软件中心包：easytier_hnd.tar.gz、easytier_qca.tar.gz
- 支持处理器：ARMv7（armv7l）和 ARM64（aarch64）。ARMv6 未声明支持，因为构建基线是官方 ARMv7 核心。
- RT-AX56U 的 armv7l 架构会选择包内 bin/easytier-core_arm32，安装后映射为 /koolshare/bin/easytier-core。
- .valid 文件仍放在解压目录 easytier/.valid，内容分别为 hnd 或 qca。

## KoolShare 离线安装

1. 从本仓库 [Releases](https://github.com/404404/easytier-merlin/releases) 下载 easytier_hnd.tar.gz 或 easytier_qca.tar.gz，并一并下载 SHA256SUMS。
2. 在电脑上校验：sha256sum --check SHA256SUMS。
3. 在 KoolShare 软件中心使用“离线安装”上传与固件平台相符的包。
4. 安装会备份要替换的插件脚本和页面。现有 easytier-core、/koolshare/configs/easytier.conf、网络名称、密钥、节点配置和 easytier_autostart DBUS 值会保留。
5. 安装不会重启或启动正在运行的 EasyTier。安装完成后，在 Web 页面或 SSH 手动启动。

SSH 手动安装时，先将归档上传到路由器 /tmp：

    cd /tmp
    tar -xzf easytier_hnd.tar.gz
    sh /tmp/easytier/install.sh

如果软件中心解压目录名称不同，请将最后一条命令改为实际的 install.sh 路径。

## 自启动机制

- V99easytier.sh 由 KoolShare services-start 的 V* 事件调用，作为 AP 模式启动入口。
- S99easytier.sh 处理 wan-start 的 S* 事件，作为补充入口。
- 两个入口都将工作异步放到后台，不会等待网络或阻塞其他 KoolShare 插件。服务脚本通过原子目录互斥锁避免并发启动。
- 启动时只检查 IPv4 路由或非回环 IPv4 地址，不等待 IPv6；IPv4 尚未就绪时最多重试 30 次，每次间隔 2 秒。
- N99easytier.sh 不停止 EasyTier，避免 NAT 初始化事件误停服务。
- 自动启动只在 dbus get easytier_autostart 返回 1 时生效。关闭后，冷启动事件会跳过服务。
- 自启动依赖已有非空 /koolshare/configs/easytier.conf 和可执行核心。

## CLI 操作

通过 SSH 执行：

    sh /koolshare/scripts/easytier_config.sh start
    sh /koolshare/scripts/easytier_config.sh stop
    sh /koolshare/scripts/easytier_config.sh restart
    sh /koolshare/scripts/easytier_config.sh status

CLI start 不保存、不重写配置。服务脚本通过 PID 文件和 /proc 命令行核对进程确实以插件核心路径及配置文件启动；无效 PID 文件不会被用于发信号。停止先发 TERM，超时后才对已核实的插件进程发 KILL，不使用 killall easytier-core。

Web 表单保留配置保存、日志弹窗和异步提交。CLI 操作则同步返回退出码；错误写入 /tmp/upload/easytier_log.txt，核心输出写入 /tmp/upload/easytier_runtime.log。

新版本将自己的防火墙规则放在 EasyTier 专用链中。升级时如果发现旧版未标记的直连规则，脚本会保留它们并避免再次添加相同规则；由于无法证明这类旧规则的所有权，停止或卸载时也不会自动删除它们。

## 升级、备份与回滚

插件升级会更新插件脚本、Web 页面和 V/S/N 事件入口：

- 保留现有核心二进制；核心更新与插件更新分离。
- 保留现有配置文件及 EasyTier 网络配置 DBUS 数据。
- 不强制重启服务，也不运行可能触发设备已知 SIGABRT 的核心版本查询。
- 替换文件前，备份保存到 /koolshare/backup/easytier/<时间戳>-<PID>/。
- 安装遇到错误会尽可能自动恢复，并打印回滚路径和命令。

手动恢复最近一次或指定备份：

    sh /koolshare/scripts/easytier_rollback.sh
    sh /koolshare/scripts/easytier_rollback.sh /koolshare/backup/easytier/<时间戳>-<PID>

回滚恢复插件脚本、页面与启动入口，不改核心、配置、DBUS 网络数据，也不会自动重启服务。确认恢复后可手动运行 start。

## CI 与 Release

.github/workflows/ci.yml 在以下情况下运行：

- Pull Request：静态检查、BusyBox ash 语法、mock 生命周期与安装测试、测试核心打包结构。
- 推送到 main：上述测试通过后，再下载固定版本的官方核心、校验 SHA-256 并构建 HND/QCA 安装包。
- Actions 手动触发：打开 Actions → EasyTier CI → Run workflow；成功后从该次运行下载 easytier-packages 工件。

.github/workflows/release.yml 只响应 plugin-v* Tag。发布任务会再次执行完整 CI，检查 Tag 指向的提交已进入 main，再创建 Release 并附上两个安装包和 SHA256SUMS。已有同名 Release 不会被覆盖或重复上传。

PR 合并到 main 且 CI 全部通过后，先发布候选版：

    git tag plugin-v1.0.1-rc.1
    git push origin plugin-v1.0.1-rc.1

该 Tag 会创建 GitHub Pre-release，供离线安装包验证。只有 AX56U 实机冷启动和自启动验证通过后，才发布正式版：

    git tag plugin-v1.0.1
    git push origin plugin-v1.0.1

Release 标题和说明会分别标明插件版本与 EasyTier 官方核心构建版本。CI 不会执行 ARM 核心，也不能替代 RT-AX56U 实机测试。每次 Release 都会明确标注 AX56U 冷启动是否完成验证。

## ASUS RT-AX56U 实机验证清单

计划维护窗口内验证；本仓库 CI 不会远程重启或修改路由器。

1. 安装前记录 dbus get easytier_autostart，备份 /koolshare/configs/easytier.conf，保存 ls -l /koolshare/bin/easytier-core。
2. 安装插件后确认核心文件、配置文件和 DBUS 网络配置内容保持原状；dbus get easytier_autostart 应仍为原值。
3. 执行 status、stop、start、restart、status，确认每条命令退出码及 Web 状态/日志一致。
4. 确认 Web 页面将设备核心版本显示为“未知”，并且安装过程没有调用核心 --version。
5. 分别以自启动为 0 与 1 验证 services-start；启用时确认 IPv4 就绪后仅运行一个实例。
6. 检查 start_nat 不会停止服务，并在维护窗口安排冷启动验证 V* 入口。观察其他 KoolShare 插件、Lucky 和现有 IPv6 修复脚本是否正常。
7. 记录 AX56U 型号、固件版本、测试时间、启动日志和结果，再将 Release 的实机验证状态更新为已完成。

## 卸载

执行：

    sh /koolshare/scripts/uninstall_easytier.sh

卸载只移除插件脚本、Web 页面、图标、启动入口和软件中心注册项。为避免误删用户或其他插件数据，现有 easytier-core、easytier.conf、EasyTier DBUS 配置及升级备份会保留。
