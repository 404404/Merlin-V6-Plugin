# AP IPv6 Manager v0.1.0

**中文名称：AP IPv6 管理** · **内部模块：`apipv6`**

这是一个面向 ASUS Merlin / KoolShare 固件 AP 模式的独立 IPv6 客户端管理插件。它检查 `br0` 上的 SLAAC 参数、IPv6 地址与默认路由，并可在用户启用后恢复 `br0` 的三个接口级参数。

本项目当前处于开发版。CI 模拟测试不能代替真实 Merlin 固件与 RT-AX56U 的验收。

## 适用范围

- Merlin 固件、KoolShare 软件中心可用的设备。
- AP 模式通过固件模式字段判断；仅当 `nvram get sw_mode` 为 `3` 且 `nvram get wlc_psta` 为 `0` 时允许修复。
- 目标故障场景是 AP 自身的 `br0` SLAAC 客户端设置被关闭或覆盖。
- HND 与 QCA 包包含相同的 Shell 插件文件，仅 `.valid` 平台标记不同。安装时请选择与软件中心平台相符的包。

插件不适用于需要路由、DHCPv6 Server、RA Server 或 IPv6 转发配置的用途。非 AP 模式仍可查看状态，但修复命令会拒绝写入。

## 安装

1. 从 GitHub Actions Artifact 下载 `apipv6_hnd.tar.gz` 或 `apipv6_qca.tar.gz`，并下载同一次构建的 `SHA256SUMS`。
2. 在电脑上执行 `sha256sum --check SHA256SUMS`。
3. 将对应离线包上传到 KoolShare 软件中心并安装。
4. 安装器会检查固件命令、包标记与脚本语法，备份将被覆盖的插件文件，并注册 Web 页面。

安装默认将自动修复、周期检查和异常自动修复全部设为关闭。安装器不会调整 IPv6 参数，也不会重启网络。

## Web 管理

页面为 KoolShare 软件中心的 **AP IPv6 管理**，包含：

- 当前模式、健康状态、首选全球单播地址、地址前缀、RA 默认网关与探测结果。
- br0 上全部 IPv6 地址、类型、Preferred / Deprecated 状态、前缀长度与生命周期。
- 自动修复、开机延迟、周期检查间隔与异常时修复开关。
- 立即检查、异步手动修复、最近修复结果与插件日志。

页面通过插件自己的 `/_api/` 请求调用与 CLI 相同的脚本。后台修复会轮询任务状态；页面超时或断开时会显示“未确认”，不会把未完成任务显示为成功。

动态值写入 `textContent`，页面不会将路由器返回的数据拼进 HTML。

## 自动修复与健康检查

在页面中分别设置：

- **启用开机自动修复与插件任务**：默认关闭。启用后，V99 启动入口会在设定延迟后进行最多 3 次有限检查。
- **开机延迟**：0–180 秒，默认 30 秒。
- **周期健康检查**：默认关闭；启用后由固件 `cru` 维护独立的 `apipv6_health` 定时任务。
- **异常自动修复**：默认关闭。启用后，只在检查发现 br0 参数、首选地址或默认路由异常时尝试修复。公网 Ping 失败本身不会触发修改。
- **健康检查间隔**：5–60 分钟，默认 15 分钟。

每次修复最多等待 RA / SLAAC 结果 30 秒，然后记录真实结果；启动任务最多重试 3 次。若上游没有发送 RA，插件会报告超时，不会重启接口或不断循环。

AP 模式需要 `disable_ipv6=0`、`autoconf=1`、`accept_ra=2`。修复只写入：

```text
net.ipv6.conf.br0.disable_ipv6
net.ipv6.conf.br0.autoconf
net.ipv6.conf.br0.accept_ra
```

插件不写全局 IPv6 参数，不修改其他接口、IPv4、路由表、防火墙、转发、上游网关、地址或前缀。已存在的旧地址不会被清除。

## CLI

```sh
/koolshare/scripts/apipv6_config.sh status
/koolshare/scripts/apipv6_config.sh status --json
/koolshare/scripts/apipv6_config.sh check
/koolshare/scripts/apipv6_config.sh repair
/koolshare/scripts/apipv6_config.sh start
/koolshare/scripts/apipv6_config.sh stop
/koolshare/scripts/apipv6_config.sh restart
/koolshare/scripts/apipv6_config.sh version
```

`status` 只读。`stop` 会关闭本插件的自动任务和定时任务，但不会关闭系统 IPv6、删除地址或路由。

退出码：`status` 成功采集时为 0；`check` 对正常、部分异常和非 AP 模式返回 0，对需处理的网络异常返回 2，检测错误返回 4；`repair` 成功或网络部分可用返回 0，等待 RA 超时返回 2，其他修复错误返回 3，非 AP 模式返回 5。

JSON 状态字段包括 `health`、`mode`、`bridge`、`sysctl`、`addresses`、`preferred_ipv6`、`prefix`、`default_route`、`default_gateway`、`public_connectivity`、自动任务设置、最近检查/修复时间和迁移状态。地址列表会把 link-local、ULA、全球单播、temporary、preferred 与 deprecated 分开表示。首选地址规则是：仅考虑 br0 上的 preferred 全球单播地址，并按 `ip` 返回顺序取第一个；temporary 地址仍在明细中显示。

健康状态：`normal` 正常；`partial` 地址和路由正常但探测失败或不可用；`address_error` 缺少 preferred 全球单播地址；`route_error` 缺少 IPv6 默认路由；`parameter_error` sysctl 不符合要求；`waiting_ra` 参数已修复但暂未收到有效 RA；`not_applicable` 非 AP 模式；`detection_error` 系统状态无法读取。

公网连通性使用一次带超时的 ICMPv6 探测。探测失败会保留为诊断结果，不会单独判定 SLAAC 已坏，因为目标可能过滤 ICMPv6。

## 旧 `V00apipv6.sh` 迁移

安装器读取旧入口并计算 SHA-256。只有脚本内容严格匹配本插件认可的三条 br0 SLAAC 写入语句时，才会先备份到 `/koolshare/backup/apipv6/` 并记录 `known_pending`。其他内容视为用户脚本，保持原样并标为 `conflict`。

新插件安装验证通过后仍不会禁用旧入口。只有用户启用自动修复，并有一次修复成功验证，迁移工具才会再次核对 SHA-256 并移动已知旧入口。手动卸载或回滚时会在目标路径空闲且校验通过时恢复旧脚本。若路径已有不同内容，插件不会覆盖它。日志和迁移备份在卸载后保留。

## 升级、卸载与回滚

- 升级前会把将覆盖的插件文件保存到 `/koolshare/backup/apipv6/upgrade-*`，并记录 DBUS 设置快照。
- 升级保留用户开关与间隔，不会自动运行修复。
- 卸载仅删除本插件明确拥有的文件、启动钩子、注册信息和定时任务；保留日志、设置和备份，不清除已获取的 IPv6 地址或路由。
- 回滚命令：

  ```sh
  sh /koolshare/scripts/apipv6_rollback.sh /koolshare/backup/apipv6/upgrade-时间戳-PID
  ```

回滚会先停止本插件任务，再恢复文件、DBUS 快照和已迁移的旧入口。回滚操作不会重置网络。

## 常见问题

- **离线安装提示缺少 `nvram` 或 `dbus`**：软件中心调用安装脚本时可能没有继承固件或 KoolShare 的命令目录。安装器和运行时会检查 `/usr/sbin`、`/koolshare/bin` 等固件目录；仍报错时，请检查对应可执行文件是否存在。
- **状态显示不适用**：检查 `nvram get sw_mode` 与 `nvram get wlc_psta`。只有值分别为 `3` 与 `0` 时插件才会写 br0 参数。
- **参数正常但没有地址**：确认上游 RA 已到达桥接网络；插件不会替上游配置 RA 或 DHCPv6。
- **地址和默认路由正常但探测失败**：保留探测失败诊断，检查上游策略或 ICMPv6 目标过滤；这不会单独触发修复。
- **旧脚本冲突**：先在页面查看 SHA-256 与迁移状态。用户脚本必须自行检查并备份后处理，插件不会自动覆盖。
- **周期检查没有运行**：检查固件是否提供 `cru`，并确认周期健康检查开关已启用。

## 开发检查与产物

```sh
make all
sh scripts/check_package.sh
sh tests/run.sh
node tests/test_web.js
```

CI 在 Linux Runner 上执行 POSIX sh / BusyBox ash / ShellCheck、Mock 集成测试、前端行为检查、HND/QCA 包结构和 SHA-256 校验，并上传保留 14 天的 `apipv6-packages` Artifact。不会部署到真实路由器。

## RT-AX56U 实机验收

验收命令、冷启动步骤、迁移与回滚步骤见 [docs/AX56U-ACCEPTANCE.md](docs/AX56U-ACCEPTANCE.md)。该过程尚未在真实 RT-AX56U 上执行。
