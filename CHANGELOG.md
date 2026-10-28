# 更新记录

## 0.1.0 — 开发版

- RC7：修复 Web 后端未读取 KoolShare 请求编号、未加载 base.sh 与未发送 http_response 导致的页面超时；覆盖状态、日志、检查、保存及异步修复回调。
- WebUI 沿用 Merlin / KoolShare 原生顶部栏、侧边菜单、标签页、FormTitle/FormTable 与按钮/输入框皮肤，移除独立白底 Bootstrap 页面。
- 保存配置改用请求专属暂存键，防止 httpdb 在后台校验之前覆盖正式设置；校验或定时任务失败时保留原配置。
- 安装语法检查和路由器回滚示例使用 /bin/sh，避免 Broadcom 同名 sh 内存工具；新增“同名工具返回 0 但脚本语法无效”的拒绝测试。
- 新增已安装插件的真实 HTTP 回归链，普通 Shell 和 Merlin 精简 ash 环境都执行；超时页面显示读取失败，开机延迟 0 正确保留。
- 修复 Merlin BusyBox ash 关闭 `command` 内建时误报所有基础工具缺失的问题；命令检测改为检查 PATH 中的可执行文件。
- 旧 V00 迁移支持 OpenSSL SHA-256；校验失败或摘要无效时保留旧脚本。
- CI 增加 BusyBox 1.25.1 关闭 `command` 内建、缺少 `sha256sum` 时的完整功能与生命周期测试。
- 新建独立 Merlin AP IPv6 Manager 插件与 KoolShare Web 管理页。
- 添加 br0 SLAAC 状态、地址分类、首选前缀、默认路由和 ICMPv6 诊断。
- 添加 AP 模式保护下的有限、幂等手动和开机修复。
- 添加可选 `cru` 健康检查、CLI、异步 Web 修复与有界日志。
- 添加严格匹配的 `V00apipv6.sh` 备份、迁移和恢复。
- 添加安装、升级备份、卸载、回滚、Mock 测试、CI 与 HND/QCA 离线包。
- 修复受限 PATH 下离线安装无法查找固件 `nvram` 与 KoolShare `dbus` 的问题。
- 安装、运行、迁移、卸载和回滚入口统一补齐固件与 KoolShare 命令路径；`ip` 可从 PATH 外的固件目录解析。
- 初次安装默认关闭自动修复、周期检查与异常修复。
