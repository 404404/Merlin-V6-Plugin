# 更新记录

## 0.1.0 — 开发版

- 新建独立 Merlin AP IPv6 Manager 插件与 KoolShare Web 管理页。
- 添加 br0 SLAAC 状态、地址分类、首选前缀、默认路由和 ICMPv6 诊断。
- 添加 AP 模式保护下的有限、幂等手动和开机修复。
- 添加可选 `cru` 健康检查、CLI、异步 Web 修复与有界日志。
- 添加严格匹配的 `V00apipv6.sh` 备份、迁移和恢复。
- 添加安装、升级备份、卸载、回滚、Mock 测试、CI 与 HND/QCA 离线包。
- 修复受限 PATH 下离线安装无法查找固件 `nvram` 与 KoolShare `dbus` 的问题。
- 初次安装默认关闭自动修复、周期检查与异常修复。
