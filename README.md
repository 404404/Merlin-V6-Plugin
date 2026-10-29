# EasyTier KoolShare 插件

本仓库维护 KoolShare Merlin 软件中心插件，用于在华硕路由器上运行 EasyTier。

开发及维护分支：[EasyTier-Merlin](https://github.com/404404/Merlin-V6-Plugin/tree/EasyTier-Merlin)。默认 `Main` 刻意保留为空；AP IPv6 插件在独立分支维护。

## 正式版下载

- [EasyTier 插件 v1.1.0 Release](https://github.com/404404/Merlin-V6-Plugin/releases/tag/plugin-v1.1.0)
- **ASUS RT-AX56U / KoolShare HND 固件：[easytier_hnd.tar.gz](https://github.com/404404/Merlin-V6-Plugin/releases/download/plugin-v1.1.0/easytier_hnd.tar.gz)**
- QCA 固件：[easytier_qca.tar.gz](https://github.com/404404/Merlin-V6-Plugin/releases/download/plugin-v1.1.0/easytier_qca.tar.gz)
- [SHA256SUMS](https://github.com/404404/Merlin-V6-Plugin/releases/download/plugin-v1.1.0/SHA256SUMS)

## 版本与核心

- 正式插件版本：**1.1.0**（AP 自启动、节点信息与安全版本识别）
- 新安装包的核心构建基线：**EasyTier 官方 v2.6.4**
- 核心来源：官方 [EasyTier v2.6.4 Release](https://github.com/EasyTier/EasyTier/releases/tag/v2.6.4)，构建前按仓库 Makefile 中固定的 SHA-256 校验。
- 插件升级会默认保留设备上现有的 easytier-core。插件版本、构建包核心版本和设备当前核心版本是不同信息。
- 设备当前核心版本通过本机 RPC 返回值读取；也可对运行中程序的文件指纹作精确匹配。不会运行 easytier-core --version。无法识别时明确显示“未知”；安装包内 v2.6.4 不代表设备现装核心版本。

已实现插件生命周期、AP 模式自启动、升级保护、只读节点面板、安全版本识别和自动构建发布。升级默认保留设备核心。

### RT-AX56U 实机反馈

| 项目 | 用户反馈及验证边界 |
| --- | --- |
| AP 模式重启自启动 | 2026-10-28 用户反馈重启后能够自行启动 |
| Web 功能及节点数据采集 | 2026-10-29 用户安装 RC2 后确认功能、数据采集正常 |
| 设备核心版本 | 后端已通过文件指纹识别 v2.6.4，并通过本机 RPC 返回节点版本 |
| 软件中心图标 | 2026-10-29 用户随后确认图标已正常显示，先前未更新疑似浏览器缓存；正式版移除页面内额外图标 |
| 断电后冷启动、其他型号与固件 | 尚无逐项验证记录；CI 及上述反馈不能替代这些实机验证 |

此次正式发布获得用户确认。记录的是用户已反馈的结果，不扩大为所有设备、全部测试场景均已通过。

## 节点信息与核心版本

- 对齐官方 GUI 常用信息：节点名称、虚拟 IP、直连/中继、延迟、丢包、累计接收/发送、协议和节点版本。流量表示连接累计值，不是实时网速；中继节点不推断丢包和流量，显示“—”，缺少字段也不会伪造为零。
- 安装包从同一份已校验的官方 v2.6.4 ZIP 提取对应架构的 `easytier-cli`，安装为 `/koolshare/bin/easytier-cli-plugin`（约 2.3 MB）。查询工具和现有核心是独立文件；升级只新增/更新插件查询工具，保留现有核心以及用户自行安装的 `easytier-cli`。
- 查询固定执行 `easytier-cli-plugin -p 127.0.0.1:<端口> --output json peer`，不会执行核心版本命令或写入配置。只连接回环地址，并用端口所属 PID 验证目标是插件管理的进程。默认端口为 15888，也支持配置中明确设置的本机端口。
- 采用官方 CLI 的普通 peer JSON 行列表，不调用可能包含完整配置和密钥的 verbose/node/config 查询。面板通过软件中心现有 API 返回数据，查询缓存位于权限为 700 的私有 `/tmp/easytier-nodes` 目录。
- 页面可手动刷新；默认每 15 秒刷新，隐藏页面暂停请求。同一时间只运行一个查询工具，成功缓存 10 秒，失败退避 60 秒；CLI 运行最多等待约 4 秒，并限制输出大小，异常不会停止核心。
- 不要求设备安装 jq。文件指纹识别在可用时使用 sha256sum、BusyBox 对应 applet 或 OpenSSL；缺少工具时仍可通过 RPC 读取版本。只接受本机节点行的版本，绝不使用远端节点或 CLI 自身版本冒充核心版本。
- 如 RPC 被关闭、端口无法核实或 CLI 与设备核心不兼容，会明确显示不可用原因，保留现有组网服务。其他设备需单独确认查询工具与现装核心的兼容性。
- RC2 修复旧版 KoolShare httpdb 不转义回调 JSON 的问题：Web API 使用带版本前缀的 Base64 封装，SSH `nodes` 命令仍输出普通 JSON。查询结果限制为 64 KiB，确保经过封装后不超过固件单个命令参数的长度限制。节点提示显示在自动刷新选项旁，核心版本显示在状态表内。
- 软件中心图标同步自官方 v2.6.4 [128×128 GUI 图标](https://github.com/EasyTier/EasyTier/blob/8428a89d2dabc94c97d370ec607c6ca142473626/easytier-gui/src-tauri/icons/128x128.png)，保持原始文件；SHA-256 为 `3ba8f0b0a7cd03127e2f088867181cb5ffc8b214182ac69d2ab32d58974f3bea`，许可证附在 `res/EasyTier-LICENSE`。安装到 `/koolshare/res/icon-easytier.png`，对应软件中心请求 `/res/icon-easytier.png`。插件页面移除额外图标和自定义 favicon。
- 升级后用 Ctrl+F5 强制刷新软件中心及插件页面；手机浏览器可清除路由器站点缓存后重新打开。软件中心使用固定图标 URL，浏览器可能继续显示缓存的旧图；本插件不会修改软件中心页面或其他插件来强制刷新缓存。

字段依据：[官方 CLI peer 输出实现](https://github.com/EasyTier/EasyTier/blob/v2.6.4/easytier/src/easytier-cli.rs)、[官方 GUI 状态页面](https://github.com/EasyTier/EasyTier/blob/v2.6.4/easytier-web/frontend-lib/src/components/Status.vue)。

## 支持平台与架构

- KoolShare 软件中心包：easytier_hnd.tar.gz、easytier_qca.tar.gz
- 支持处理器：ARMv7（armv7l）和 ARM64（aarch64）。ARMv6 未声明支持，因为构建基线是官方 ARMv7 核心。
- RT-AX56U 的 armv7l 架构会选择包内 bin/easytier-core_arm32，安装后映射为 /koolshare/bin/easytier-core。
- .valid 文件仍放在解压目录 easytier/.valid，内容分别为 hnd 或 qca。

## KoolShare 离线安装

1. 从本仓库 [Releases](https://github.com/404404/Merlin-V6-Plugin/releases) 下载 easytier_hnd.tar.gz 或 easytier_qca.tar.gz，并一并下载 SHA256SUMS。
2. 在电脑上校验：下载两个包时运行 `sha256sum --check SHA256SUMS`；仅下载 HND 包时运行 `grep '  easytier_hnd.tar.gz$' SHA256SUMS | sha256sum --check -`。不要求在路由器上安装 sha256sum。
3. 在 KoolShare 软件中心使用“离线安装”上传与固件平台相符的包。
4. 安装会备份要替换的插件脚本和页面。现有 easytier-core、/koolshare/configs/easytier.conf、网络名称、密钥、节点配置和 easytier_autostart DBUS 值会保留。
5. 安装保留现有服务进程，不会重启或启动服务。若原本未运行，可在 Web 页面或 SSH 手动启动。
6. Ctrl+F5 强制刷新页面，确认核心版本、节点信息和软件中心图标。插件页面内不再显示额外图标。

SSH 手动安装时，先将归档上传到路由器 /tmp：

    cd /tmp
    tar -xzf easytier_hnd.tar.gz
    sh /tmp/easytier/install.sh

如果软件中心解压目录名称不同，请将最后一条命令改为实际的 install.sh 路径。

兼容旧版 Merlin ash：安装器和服务脚本使用固件支持的 `type` 检测命令及软件中心函数，不依赖部分固件未编译的 `command` 内建命令。脚本也会补齐 KoolShare 和系统工具目录的 PATH。若安装检查失败且尚未替换文件，日志会明确说明无需回滚。

## 自启动机制

- V99easytier.sh 由 KoolShare services-start 的 V* 事件调用，作为 AP 模式启动入口。
- S99easytier.sh 处理 wan-start 的 S* 事件，作为补充入口。
- 两个入口都将工作异步放到后台，不会等待网络或阻塞其他 KoolShare 插件。服务脚本通过原子目录互斥锁避免并发启动。
- 启动时只检查 IPv4 路由或非回环 IPv4 地址，不等待 IPv6；IPv4 尚未就绪时最多重试 30 次，每次间隔 2 秒。
- N99easytier.sh 不停止 EasyTier，避免 NAT 初始化事件误停服务。
- 自动启动只在 dbus get easytier_autostart 返回 1 时生效。关闭后，冷启动事件会跳过服务。
- 开机任务等待网络或服务互斥锁后都会重新检查开关，避免已关闭自启动时被旧后台任务重新拉起。
- 自启动依赖已有非空 /koolshare/configs/easytier.conf 和可执行核心。

## CLI 操作

通过 SSH 执行：

    sh /koolshare/scripts/easytier_config.sh start
    sh /koolshare/scripts/easytier_config.sh stop
    sh /koolshare/scripts/easytier_config.sh restart
    sh /koolshare/scripts/easytier_config.sh status
    sh /koolshare/scripts/easytier_config.sh nodes

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
- 推送到开发分支 `EasyTier-Merlin`：上述测试通过后，再下载固定版本的官方核心、校验 SHA-256 并构建 HND/QCA 安装包。
- Actions 手动触发：打开 Actions → EasyTier CI → Run workflow；成功后从该次运行下载 easytier-packages 工件。

.github/workflows/release.yml 只响应 plugin-v* Tag。发布任务会再次执行完整 CI，检查 Tag 指向的提交已进入 `EasyTier-Merlin`，再创建 Release 并附上两个安装包和 SHA256SUMS。已有同名 Release 不会被覆盖或重复上传。

后续版本更新到 `EasyTier-Merlin` 且 CI 全部通过后，可用新的版本号发布候选版，例如：

    git tag -a plugin-v1.1.1-rc.1 <已通过CI的提交SHA> -m 'EasyTier plugin 1.1.1 RC1'
    git push origin plugin-v1.1.1-rc.1

候选版 Tag 会创建 GitHub Pre-release，供离线安装包验证。取得用户发布确认、如实记录实机验证范围并通过完整 CI 后，正式 Tag（不含 `-rc.N`）会生成非预发布 Release。v1.1.0 使用 `plugin-v1.1.0`；以下为后续版本示例（需先同步插件版本元数据）：

    git tag -a plugin-v1.1.1 <已通过CI的提交SHA> -m 'EasyTier plugin 1.1.1'
    git push origin plugin-v1.1.1

已发布的 Tag 不覆盖或移动；候选版编号也不可重复使用。默认 `Main` 保持为空，不需要将此分支合并回 Main 才能发布。

Release 标题和说明会分别标明插件版本与 EasyTier 官方核心构建版本。CI 不会执行 ARM 核心，也不能替代 RT-AX56U 实机测试。每次 Release 都会明确标注 AX56U 冷启动是否完成验证。

## ASUS RT-AX56U 实机验证清单

计划维护窗口内验证；本仓库 CI 不会远程重启或修改路由器。

1. 安装前记录 dbus get easytier_autostart，备份 /koolshare/configs/easytier.conf，保存 ls -l /koolshare/bin/easytier-core。
2. 安装插件后确认核心文件、配置文件和 DBUS 网络配置内容保持原状；dbus get easytier_autostart 应仍为原值。
3. 执行 status、stop、start、restart、status，确认每条命令退出码及 Web 状态/日志一致。
4. 确认 Web 页面版本来源为本机 RPC 或精确文件指纹，不能以查询工具的版本替代核心版本；无法读取时显示“未知”，不调用核心 --version。
5. 分别以自启动为 0 与 1 验证 services-start；启用时确认 IPv4 就绪后仅运行一个实例。
6. 检查 start_nat 不会停止服务，并在维护窗口安排冷启动验证 V* 入口。观察其他 KoolShare 插件、Lucky 和现有 IPv6 修复脚本是否正常。
7. 记录 AX56U 型号、固件版本、测试时间、启动日志和结果，再将 Release 的实机验证状态更新为已完成。
8. 对比官方 GUI 的节点信息，检查中文及特殊字符名称显示、直连/中继、延迟/丢包和累计流量；停止服务后不能保留旧节点列表，RPC 故障时不能影响组网。

## 卸载

执行：

    sh /koolshare/scripts/uninstall_easytier.sh

卸载只移除插件脚本、Web 页面、图标、启动入口和软件中心注册项。为避免误删用户或其他插件数据，现有 easytier-core、easytier.conf、EasyTier DBUS 配置及升级备份会保留。
