# RT-AX56U AP 模式实机验收

此流程用于用户在真实设备上自行验收。CI 不会登录 AX56U，也不会修改设备。安装与启用自动修复前，请先保留可恢复的设备配置和当前启动脚本。

## 1. 安装前只读记录

通过设备 SSH 运行：

```sh
nvram get productid
nvram get sw_mode
nvram get wlc_psta
ip link show dev br0
cat /proc/sys/net/ipv6/conf/br0/disable_ipv6
cat /proc/sys/net/ipv6/conf/br0/autoconf
cat /proc/sys/net/ipv6/conf/br0/accept_ra
ip -6 addr show dev br0
ip -6 route show default
ls -l /koolshare/init.d/V00apipv6.sh
sha256sum /koolshare/init.d/V00apipv6.sh 2>/dev/null
```

确认 `sw_mode` 为 `3`、`wlc_psta` 为 `0`、`br0` 存在，并记录安装前参数、全部 IPv6 地址与路由。若旧 `V00apipv6.sh` 存在，先自行复制到安全位置并记录 SHA-256。

## 2. 安装与关闭状态验收

1. 按设备软件中心提供的平台标记选择 HND 或 QCA 包。
2. 安装后确认页面显示模式、`br0` 地址类型、Preferred / Deprecated、默认路由和探测结果。
3. 确认自动修复、周期检查和异常自动修复默认关闭。
4. 执行 `status` 与 `status --json`，确认只读操作没有改变三项 sysctl、地址、路由、防火墙或其他接口。
5. 若 `V00apipv6.sh` 存在，确认安装没有覆盖或删除它，并核对页面显示的迁移状态与 SHA-256。

## 3. 手动修复

在页面点击“立即修复”前记录以下内容；或通过 SSH 执行 `/koolshare/scripts/apipv6_config.sh repair`：

```sh
date
cat /proc/sys/net/ipv6/conf/br0/disable_ipv6
cat /proc/sys/net/ipv6/conf/br0/autoconf
cat /proc/sys/net/ipv6/conf/br0/accept_ra
ip -6 addr show dev br0
ip -6 route show default
```

修复后重复只读命令，确认只有 `br0` 的三项参数可能变化为 `0 / 1 / 2`。观察 RA 到达时间、首选全球单播地址、旧 deprecated 地址、新 preferred 地址、前缀变化和默认下一跳。确认地址和路由正常后，再查看有超时限制的 ICMPv6 探测结果。

## 4. 冷启动与参数覆盖

1. 先保持自动修复关闭，冷启动一次，确认启动入口没有修改网络。
2. 记录 `/koolshare/init.d/V99apipv6.sh` 的执行时间；入口应立即返回，后台等待时间不阻塞启动流程。
3. 在页面启用自动修复，设置 30 秒延迟；重启设备。
4. 在启动后约 30–180 秒重复采集三项 sysctl、`ip -6 addr`、默认路由和插件日志，确认有限重试期间能重新检测系统后续覆盖。
5. 断开上游 RA 或暂时拔除上联时，只观察超时诊断，不应看到接口重启、地址清除、防火墙变化或无限循环。

## 5. 周期检查与开关

1. 开启周期健康检查，确认 `cru l` 中只新增名为 `apipv6_health` 的任务。
2. 若要测试异常自动修复，再单独打开对应开关；公网探测失败本身不应改 sysctl。
3. 关闭自动修复并周期检查，再执行页面检查与 CLI `check`，确认只读检测仍可用。
4. 执行 CLI `stop`，确认只停止插件任务，不关闭 IPv6、不删除地址或默认路由；通过 Web 再次启用后确认任务恢复。

## 6. 旧入口迁移与回滚

只对可丢弃的测试配置验证：

1. 对照安装备份目录记录的 `path`、SHA-256 和迁移状态。
2. 已知旧脚本只有在启用自动修复且一次修复成功后才会迁移；自定义内容应始终保持在原路径并显示冲突。
3. 已迁移旧脚本时，使用测试卸载或回滚，确认只在原路径空闲时恢复备份。
4. 在 `/koolshare/init.d/V00apipv6.sh` 放入不同内容后，确认卸载和回滚拒绝覆盖，并保留日志及备份。

## 验收记录模板

记录固件版本、设备平台、安装包 SHA-256、安装前后模式和 sysctl、启动入口时间、RA 等待时间、地址分类与前缀、默认路由、Ping 结果、插件日志、开关行为、旧脚本 SHA-256、卸载/回滚结果。真实设备结果需由测试者填写；CI 结果不能替代它。
