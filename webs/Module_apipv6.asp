<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="-1">
<title>软件中心 - AP IPv6 管理</title>
<link rel="stylesheet" type="text/css" href="/index_style.css">
<link rel="stylesheet" type="text/css" href="/form_style.css">
<link rel="stylesheet" type="text/css" href="/usp_style.css">
<link rel="stylesheet" type="text/css" href="/css/element.css">
<link rel="stylesheet" type="text/css" href="/res/softcenter.css">
<script type="text/javascript" src="/js/jquery.js"></script>
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script type="text/javascript" src="/help.js"></script>
<script type="text/javascript" src="/js/httpApi.js"></script>
<script type="text/javascript" src="/general.js"></script>
<script type="text/javascript" src="/client_function.js"></script>
<script type="text/javascript" src="/res/softcenter.js"></script>
<style>
/* Use firmware FormTitle/FormTable/button/input skins; scope layout to plugin. */
.apipv6-content { width: 760px; }
.apipv6-content .formfonttitle { margin: 8px 5px; }
.apipv6-content .apipv6-version { font-size: 13px; margin-left: 8px; }
.apipv6-content .apipv6-panel { margin-top: 14px; }
.apipv6-content .FormTable { width: 100%; }
.apipv6-content .FormTable th { width: 32%; }
.apipv6-content .FormTable td { overflow-wrap: anywhere; word-break: break-word; }
.apipv6-content .apipv6-note { margin: 10px 5px; line-height: 1.7; }
.apipv6-content .apipv6-actions { margin: 12px 0; text-align: center; }
.apipv6-content .button_gen { margin: 3px; }
.apipv6-content input.apipv6-time-input { width: 120px; min-width: 120px; box-sizing: border-box; }
.apipv6-content .apipv6-state { font-weight: bold; }
.apipv6-content .state-normal, .apipv6-content .message-ok { color: #7be0a3; }
.apipv6-content .state-partial, .apipv6-content .state-waiting_ra { color: #ffcc66; }
.apipv6-content .state-parameter_error, .apipv6-content .state-address_error,
.apipv6-content .state-route_error, .apipv6-content .state-detection_error,
.apipv6-content .message-error { color: #ff9494; }
.apipv6-content .apipv6-address-scroll { width: 730px; overflow-x: auto; }
.apipv6-content .apipv6-addresses th { width: auto; white-space: nowrap; color: inherit; }
.apipv6-content .apipv6-addresses td { min-width: 70px; white-space: nowrap; word-break: normal; }
.apipv6-content .apipv6-addresses td:first-child { min-width: 190px; }
#apipv6-log { box-sizing: border-box; width: 100%; height: 200px; resize: vertical; font-family: monospace; }
#apipv6-message { min-height: 24px; margin: 8px 5px; }
.apipv6-content .apipv6-back { float: right; margin-right: 8px; }
</style>
<script>
(function () {
    "use strict";
    var taskTimer = null;
    var taskStarted = 0;
    var lastRequestId = Math.floor(Math.random() * 100000000);

    function byId(id) { return document.getElementById(id); }
    function setText(id, value) { byId(id).textContent = value == null || value === "" ? "—" : String(value); }
    function setMessage(value, isError) {
        var target = byId("apipv6-message");
        target.textContent = value || "";
        target.className = isError ? "message-error" : "message-ok";
    }
    function parseApiResponse(raw) {
        var value = raw;
        if (value && Object.prototype.hasOwnProperty.call(value, "result")) value = value.result;
        if (typeof value === "string") {
            var prefix = "apipv6-hex-v1:";
            if (value.indexOf(prefix) === 0) {
                var encoded = value.slice(prefix.length);
                if (!encoded || encoded.length % 2 || /[^0-9a-f]/i.test(encoded)) return { error: "插件响应编码无效，请刷新页面后重试。" };
                try { value = decodeURIComponent(encoded.replace(/../g, "%$&")); }
                catch (ignoreEncoding) { return { error: "插件响应字符编码无效。" }; }
            }
            try { value = JSON.parse(value); } catch (ignore) { return { error: value || "Empty response" }; }
        }
        if (!value || typeof value !== "object" || Array.isArray(value)) {
            return { error: "软件中心未返回有效的插件数据（" + String(value) + "），请确认安装后强制刷新页面。" };
        }
        return value;
    }
    function api(params, fields, timeout, done) {
        var xhr = new XMLHttpRequest();
        var finished = false;
        // Keep the same integer range used by KoolShare's own pages.
        lastRequestId = (lastRequestId + 1) % 100000000;
        var payload = { id: lastRequestId, method: "apipv6_config.sh", params: params, fields: {} };
        // httpdb persists these fields before starting the backend. Keep live
        // settings untouched until the backend has validated the whole request.
        Object.keys(fields || {}).forEach(function (key) {
            payload.fields["apipv6_websubmit_" + payload.id + "_" + key.replace(/^apipv6_/, "")] = fields[key];
        });
        function complete(data, failed) {
            if (finished) return;
            finished = true;
            done(data, failed);
        }
        xhr.open("POST", "/_api/", true);
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.timeout = timeout || 15000;
        xhr.onload = function () {
            var raw;
            try { raw = JSON.parse(xhr.responseText); }
            catch (ignore) { complete({ error: "软件中心返回的响应不是有效 JSON（HTTP " + xhr.status + "）；请确认升级后已强制刷新页面。" }, true); return; }
            complete(parseApiResponse(raw), xhr.status < 200 || xhr.status >= 300);
        };
        xhr.onerror = function () { complete({ error: "请求失败，请检查连接后重试。" }, true); };
        xhr.ontimeout = function () { complete({ error: "后端请求超时，操作结果尚未确认；请刷新状态和日志。" }, true); };
        xhr.send(JSON.stringify(payload));
    }
    function statusClass(health) {
        switch (health) {
            case "normal": return "state-normal";
            case "partial": return "state-partial";
            case "waiting_ra": return "state-waiting_ra";
            case "not_applicable": return "state-not_applicable";
            case "parameter_error": return "state-parameter_error";
            case "address_error": return "state-address_error";
            case "route_error": return "state-route_error";
            default: return "state-detection_error";
        }
    }
    function renderStatus(data) {
        if (!data || data.error) {
            setText("apipv6-health", "读取失败");
            byId("apipv6-health").className = "apipv6-state state-detection_error";
            setText("apipv6-reason", (data && data.error) || "无法读取后端状态");
            setMessage((data && data.error) || "Unable to read status", true);
            return;
        }
        var state = byId("apipv6-health");
        state.textContent = data.health_label || data.health || "未知";
        state.className = "apipv6-state " + statusClass(data.health);
        setText("apipv6-reason", data.reason);
        setText("apipv6-mode", data.ap_mode ? "AP 模式 (sw_mode=" + data.mode + ")" : "非 AP / 无法识别 (sw_mode=" + data.mode + ")");
        setText("apipv6-primary", data.preferred_ipv6);
        setText("apipv6-prefix", data.prefix);
        setText("apipv6-gateway", data.default_gateway);
        setText("apipv6-route", data.default_route ? "存在" : "缺失");
        setText("apipv6-connectivity", data.public_connectivity === "success" ? "探测成功" : data.public_connectivity === "failure" ? "探测失败（目标可能过滤 ICMPv6）" : "未知");
        setText("apipv6-updated", new Date().toLocaleString());
        setText("apipv6-last-check", data.last_check);
        setText("apipv6-last-repair", data.last_repair);
        setText("apipv6-last-failure", data.last_failure);
        setText("apipv6-migration", data.migration_status + (data.migration_sha256 ? " · SHA-256 " + data.migration_sha256 : ""));
        byId("apipv6-enabled").checked = !!data.auto_enabled;
        byId("apipv6-delay").value = data.start_delay_seconds == null ? "30" : String(data.start_delay_seconds);
        byId("apipv6-health-enabled").checked = !!data.health_check_enabled;
        byId("apipv6-interval").value = data.health_interval_minutes || "15";
        byId("apipv6-repair-on-error").checked = !!data.repair_on_error;
        renderDetails(data);
    }
    function addCell(row, value) {
        var cell = document.createElement("td");
        cell.textContent = value == null || value === "" ? "—" : String(value);
        row.appendChild(cell);
    }
    function renderDetails(data) {
        var body = byId("apipv6-address-rows");
        while (body.firstChild) body.removeChild(body.firstChild);
        (data.addresses || []).forEach(function (address) {
            var row = document.createElement("tr");
            addCell(row, address.address);
            addCell(row, address.type);
            addCell(row, address.state);
            addCell(row, address.prefix_length);
            addCell(row, address.preferred_lifetime);
            addCell(row, address.valid_lifetime);
            addCell(row, address.temporary ? "是" : "否");
            body.appendChild(row);
        });
        if (!body.firstChild) {
            var empty = document.createElement("tr");
            var cell = document.createElement("td");
            cell.colSpan = 7;
            cell.textContent = "br0 暂无 IPv6 地址";
            empty.appendChild(cell);
            body.appendChild(empty);
        }
        setText("apipv6-disable", data.sysctl && data.sysctl.disable_ipv6);
        setText("apipv6-accept-ra", data.sysctl && data.sysctl.accept_ra);
        setText("apipv6-autoconf", data.sysctl && data.sysctl.autoconf);
    }
    function refreshStatus() {
        api(["status", "--json"], {}, 10000, function (data, failed) {
            if (failed || data.error) { renderStatus({ error: data.error || "状态请求失败" }); return; }
            renderStatus(data);
        });
    }
    function refreshLog() {
        api(["logs", "web_submit"], {}, 10000, function (data, failed) {
            if (failed || data.error) { setMessage(data.error || "Log request failed", true); return; }
            byId("apipv6-log").value = data.log || "";
        });
    }
    function saveSettings() {
        var fields = {
            apipv6_enabled: byId("apipv6-enabled").checked ? "1" : "0",
            apipv6_start_delay: byId("apipv6-delay").value,
            apipv6_health_enabled: byId("apipv6-health-enabled").checked ? "1" : "0",
            apipv6_health_interval: byId("apipv6-interval").value,
            apipv6_repair_on_error: byId("apipv6-repair-on-error").checked ? "1" : "0"
        };
        setMessage("正在保存…", false);
        api(["save_config", "web_submit"], fields, 12000, function (data, failed) {
            if (failed || !data.ok) { setMessage(data.error || "配置保存失败", true); return; }
            setMessage("配置已保存；自动修复仍只会在 sw_mode=3 时运行。", false);
            refreshStatus();
        });
    }
    function runCheck() {
        setMessage("正在检查…", false);
        api(["check", "web_submit"], {}, 12000, function (data, failed) {
            if (failed || data.error) { setMessage(data.error || "检查请求失败", true); return; }
            renderStatus(data);
            setMessage("检查完成。", false);
            refreshLog();
        });
    }
    function pollTask(taskId) {
        if (Date.now() - taskStarted > 180000) {
            setMessage("修复任务状态轮询超时；结果未确认，请刷新状态和日志。", true);
            taskTimer = null;
            return;
        }
        api(["web_task", taskId, "web_submit"], {}, 10000, function (data, failed) {
            if (failed || data.error) { setMessage(data.error || "无法读取修复任务状态", true); return; }
            if (data.status === "succeeded" || data.status === "failed") {
                taskTimer = null;
                if (data.result && data.result.repair_result) {
                    setMessage("修复任务结束：" + data.result.repair_result + "。", data.status !== "succeeded");
                } else {
                    setMessage("修复任务结束；请查看日志确认结果。", data.status !== "succeeded");
                }
                refreshStatus();
                refreshLog();
                return;
            }
            setMessage(data.status === "queued" ? "修复任务排队中…" : "修复进行中…", false);
            taskTimer = window.setTimeout(function () { pollTask(taskId); }, 2000);
        });
    }
    function startRepair() {
        if (taskTimer) window.clearTimeout(taskTimer);
        setMessage("正在启动修复任务…", false);
        api(["web_repair", "web_submit"], {}, 10000, function (data, failed) {
            if (failed || !data.ok || !data.task_id) { setMessage(data.error || "无法启动修复任务", true); return; }
            taskStarted = Date.now();
            pollTask(data.task_id);
        });
    }
    function clearLog() {
        if (!window.confirm("清除 AP IPv6 Manager 日志？")) return;
        api(["clear_log", "web_submit"], {}, 10000, function (data, failed) {
            if (failed || !data.ok) { setMessage(data.error || "日志清理失败", true); return; }
            byId("apipv6-log").value = "";
            setMessage("日志已清理。", false);
        });
    }
    function init() {
        show_menu(menuHook);
        byId("apipv6-save").addEventListener("click", saveSettings);
        byId("apipv6-check").addEventListener("click", runCheck);
        byId("apipv6-repair").addEventListener("click", startRepair);
        byId("apipv6-refresh-log").addEventListener("click", refreshLog);
        byId("apipv6-clear-log").addEventListener("click", clearLog);
        refreshStatus();
        refreshLog();
        window.setInterval(refreshStatus, 20000);
    }
    function menuHook() {
        tabtitle[tabtitle.length - 1] = ["", "AP IPv6 管理"];
        tablink[tablink.length - 1] = ["", "Module_apipv6.asp"];
    }
    window.apipv6TestHooks = { parseApiResponse: parseApiResponse, statusClass: statusClass, renderDetails: renderDetails };
    window.initApipv6 = init;
}());

function init() { window.initApipv6(); }
</script>
</head>
<body id="app" skin='<% nvram_get("sc_skin"); %>' onload="init();">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" width="0" height="0" frameborder="0"></iframe>
<table class="content" align="center" cellpadding="0" cellspacing="0">
    <tr>
        <td width="17">&nbsp;</td>
        <td valign="top" width="202"><div id="mainMenu"></div><div id="subMenu"></div></td>
        <td valign="top">
            <div id="tabMenu" class="submenuBlock"></div>
            <table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
                <tr><td align="left" valign="top">
                    <table id="FormTitle" class="FormTitle apipv6-content" border="0" cellpadding="5" cellspacing="0">
                        <tr><td valign="top">
                            <div class="formfonttitle">AP IPv6 管理<span class="apipv6-version">v0.1.0</span>
                                <a class="apipv6-back" href="/Module_Softcenter.asp" title="返回软件中心"><img src="/images/backprev.png" alt="返回软件中心"></a>
                            </div>
                            <div class="splitLine"></div>
                            <p class="apipv6-note">管理设备自身 br0 上的 SLAAC 客户端参数与诊断信息。新安装默认关闭自动修复。<br>不配置 RA/DHCPv6 服务、IPv6 转发、防火墙或 IPv4。</p>

                            <div class="apipv6-panel">
                                <table class="FormTable" border="1" cellpadding="4" cellspacing="0">
                                    <thead><tr><td colspan="2">IPv6 概览</td></tr></thead>
                                    <tbody>
                                        <tr><th>健康状态</th><td><span id="apipv6-health" class="apipv6-state">读取中</span></td></tr>
                                        <tr><th>工作模式</th><td id="apipv6-mode">—</td></tr>
                                        <tr><th>Preferred 全球单播地址</th><td id="apipv6-primary">—</td></tr>
                                        <tr><th>当前前缀</th><td id="apipv6-prefix">—</td></tr>
                                        <tr><th>RA 默认网关</th><td id="apipv6-gateway">—</td></tr>
                                        <tr><th>IPv6 默认路由</th><td id="apipv6-route">—</td></tr>
                                        <tr><th>公网 ICMPv6 探测</th><td id="apipv6-connectivity">—</td></tr>
                                        <tr><th>最近刷新</th><td id="apipv6-updated">—</td></tr>
                                        <tr><th>诊断</th><td id="apipv6-reason">读取中</td></tr>
                                    </tbody>
                                </table>
                                <div class="apipv6-actions"><button type="button" id="apipv6-check" class="button_gen">立即检查</button><button type="button" id="apipv6-repair" class="button_gen">立即修复</button></div>
                            </div>

                            <div class="apipv6-panel">
                                <div class="apipv6-address-scroll">
                                    <table class="FormTable apipv6-addresses" border="1" cellpadding="4" cellspacing="0">
                                        <thead><tr><td colspan="7">IPv6 地址明细</td></tr><tr><th>IPv6 地址</th><th>类型</th><th>状态</th><th>前缀长度</th><th>Preferred 生命周期</th><th>Valid 生命周期</th><th>Temporary</th></tr></thead>
                                        <tbody id="apipv6-address-rows"></tbody>
                                    </table>
                                </div>
                                <table class="FormTable" border="1" cellpadding="4" cellspacing="0">
                                    <tbody>
                                        <tr><th>br0 disable_ipv6</th><td id="apipv6-disable">—</td></tr>
                                        <tr><th>br0 accept_ra</th><td id="apipv6-accept-ra">—</td></tr>
                                        <tr><th>br0 autoconf</th><td id="apipv6-autoconf">—</td></tr>
                                    </tbody>
                                </table>
                            </div>

                            <div class="apipv6-panel">
                                <table class="FormTable" border="1" cellpadding="4" cellspacing="0">
                                    <thead><tr><td colspan="2">自动修复设置</td></tr></thead>
                                    <tbody>
                                        <tr><th><label for="apipv6-enabled">启用开机自动修复</label></th><td><input id="apipv6-enabled" type="checkbox"> 启用插件开机任务</td></tr>
                                        <tr><th><label for="apipv6-delay">开机修复延迟</label></th><td><input class="input_3_table apipv6-time-input" id="apipv6-delay" type="number" min="0" max="180" value="30"> 秒（0–180）</td></tr>
                                        <tr><th><label for="apipv6-health-enabled">周期健康检查</label></th><td><input id="apipv6-health-enabled" type="checkbox"> 启用定时诊断</td></tr>
                                        <tr><th><label for="apipv6-interval">检查间隔</label></th><td><input class="input_3_table apipv6-time-input" id="apipv6-interval" type="number" min="5" max="60" value="15"> 分钟（5–60）</td></tr>
                                        <tr><th><label for="apipv6-repair-on-error">异常时自动修复</label></th><td><input id="apipv6-repair-on-error" type="checkbox"> 地址 / 路由 / 参数异常时修复</td></tr>
                                    </tbody>
                                </table>
                                <p class="apipv6-note">周期检查只读取状态。启用“异常时自动修复”后，才会在 AP 模式下更改 br0 的三个 SLAAC 参数。公网 Ping 失败不会单独触发修复。</p>
                                <div class="apipv6-actions"><button type="button" id="apipv6-save" class="button_gen">保存设置</button></div>
                            </div>

                            <div class="apipv6-panel">
                                <table class="FormTable" border="1" cellpadding="4" cellspacing="0">
                                    <thead><tr><td colspan="2">日志与诊断</td></tr></thead>
                                    <tbody>
                                        <tr><th>最近健康检查</th><td id="apipv6-last-check">—</td></tr>
                                        <tr><th>最近成功修复</th><td id="apipv6-last-repair">—</td></tr>
                                        <tr><th>最近修复失败原因</th><td id="apipv6-last-failure">—</td></tr>
                                        <tr><th>旧启动脚本迁移</th><td id="apipv6-migration">—</td></tr>
                                        <tr><td colspan="2"><textarea id="apipv6-log" class="input_3_table" readonly aria-label="AP IPv6 Manager 日志"></textarea></td></tr>
                                    </tbody>
                                </table>
                                <div class="apipv6-actions"><button type="button" id="apipv6-refresh-log" class="button_gen">刷新日志</button><button type="button" id="apipv6-clear-log" class="button_gen">清理插件日志</button></div>
                                <div id="apipv6-message" role="status" aria-live="polite"></div>
                            </div>
                        </td></tr>
                    </table>
                </td></tr>
            </table>
        </td>
    </tr>
</table>
<div id="footer"></div>
</body>
</html>
