<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AP IPv6 管理</title>
<link rel="stylesheet" href="/bootstrap/css/bootstrap.min.css">
<script src="/js/httpApi.js"></script>
<style>
body { font-family: Arial, "Microsoft YaHei", sans-serif; margin: 20px; color: #263238; }
.apipv6-wrap { max-width: 1180px; margin: auto; }
.apipv6-panel { border: 1px solid #d8e0e6; border-radius: 6px; margin: 14px 0; padding: 16px; background: rgba(255,255,255,.04); }
.apipv6-panel h2 { margin: 0 0 14px; font-size: 18px; }
.apipv6-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 12px; }
.apipv6-value { min-height: 42px; overflow-wrap: anywhere; }
.apipv6-label { color: #718096; font-size: 12px; margin-bottom: 4px; }
.apipv6-state { padding: 4px 9px; border-radius: 3px; display: inline-block; font-weight: bold; }
.state-normal { color: #155724; background: #d4edda; }
.state-partial,.state-waiting_ra { color: #856404; background: #fff3cd; }
.state-error,.state-parameter_error,.state-address_error,.state-route_error,.state-detection_error { color: #721c24; background: #f8d7da; }
.state-not_applicable { color: #495057; background: #e2e3e5; }
.apipv6-table { width: 100%; border-collapse: collapse; }
.apipv6-table th,.apipv6-table td { padding: 8px; border-bottom: 1px solid #d8e0e6; text-align: left; vertical-align: top; overflow-wrap: anywhere; }
.apipv6-table th { font-size: 12px; color: #718096; }
.apipv6-field { margin: 10px 0; }
.apipv6-field label { display: inline-block; min-width: 250px; }
.apipv6-field input[type=number] { width: 100px; }
.apipv6-actions { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 12px; }
.apipv6-note { color: #657786; font-size: 12px; }
#apipv6-log { width: 100%; min-height: 170px; resize: vertical; font: 12px/1.45 monospace; }
#apipv6-message { min-height: 20px; margin-top: 8px; }
button { cursor: pointer; }
</style>
<script>
(function () {
    "use strict";
    var taskTimer = null;
    var taskStarted = 0;

    function byId(id) { return document.getElementById(id); }
    function setText(id, value) { byId(id).textContent = value == null || value === "" ? "—" : String(value); }
    function setMessage(value, isError) {
        var target = byId("apipv6-message");
        target.textContent = value || "";
        target.style.color = isError ? "#b00020" : "#26734d";
    }
    function parseApiResponse(raw) {
        var value = raw;
        if (value && Object.prototype.hasOwnProperty.call(value, "result")) value = value.result;
        if (typeof value === "string") {
            try { value = JSON.parse(value); } catch (ignore) { return { error: value || "Empty response" }; }
        }
        return value || {};
    }
    function api(params, fields, timeout, done) {
        var xhr = new XMLHttpRequest();
        var payload = { id: Math.floor(Math.random() * 100000000), method: "apipv6_config.sh", params: params, fields: fields || {} };
        xhr.open("POST", "/_api/", true);
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.timeout = timeout || 15000;
        xhr.onload = function () {
            var raw;
            try { raw = JSON.parse(xhr.responseText); }
            catch (ignore) { done({ error: "Invalid API response" }, true); return; }
            done(parseApiResponse(raw), xhr.status < 200 || xhr.status >= 300);
        };
        xhr.onerror = function () { done({ error: "Request failed" }, true); };
        xhr.ontimeout = function () { done({ error: "Request timed out; task result is not confirmed." }, true); };
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
        byId("apipv6-delay").value = data.start_delay_seconds || "30";
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
            if (failed || data.error) { setMessage(data.error || "Status request failed", true); return; }
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
        byId("apipv6-save").addEventListener("click", saveSettings);
        byId("apipv6-check").addEventListener("click", runCheck);
        byId("apipv6-repair").addEventListener("click", startRepair);
        byId("apipv6-refresh-log").addEventListener("click", refreshLog);
        byId("apipv6-clear-log").addEventListener("click", clearLog);
        refreshStatus();
        refreshLog();
        window.setInterval(refreshStatus, 20000);
    }
    window.apipv6TestHooks = { parseApiResponse: parseApiResponse, statusClass: statusClass, renderDetails: renderDetails };
    window.initApipv6 = init;
}());

function init() { window.initApipv6(); }
</script>
</head>
<body id="app" skin='<% nvram_get("sc_skin"); %>' onload="init();">
<div class="apipv6-wrap">
    <h1>AP IPv6 管理 <small>AP IPv6 Manager v0.1.0</small></h1>
    <p class="apipv6-note">本插件只管理设备自身 br0 上的 SLAAC 客户端参数，不配置 RA/DHCPv6 服务、防火墙或 IPv6 转发。新安装默认不自动修复。</p>

    <section class="apipv6-panel">
        <h2>IPv6 概览</h2>
        <div class="apipv6-grid">
            <div><div class="apipv6-label">健康状态</div><div class="apipv6-value"><span id="apipv6-health" class="apipv6-state">读取中</span></div></div>
            <div><div class="apipv6-label">工作模式</div><div id="apipv6-mode" class="apipv6-value">—</div></div>
            <div><div class="apipv6-label">Preferred 全球单播地址</div><div id="apipv6-primary" class="apipv6-value">—</div></div>
            <div><div class="apipv6-label">当前前缀</div><div id="apipv6-prefix" class="apipv6-value">—</div></div>
            <div><div class="apipv6-label">RA 默认网关</div><div id="apipv6-gateway" class="apipv6-value">—</div></div>
            <div><div class="apipv6-label">IPv6 默认路由</div><div id="apipv6-route" class="apipv6-value">—</div></div>
            <div><div class="apipv6-label">公网 ICMPv6 探测</div><div id="apipv6-connectivity" class="apipv6-value">—</div></div>
            <div><div class="apipv6-label">最近刷新</div><div id="apipv6-updated" class="apipv6-value">—</div></div>
        </div>
        <p><strong>诊断：</strong><span id="apipv6-reason">读取中</span></p>
        <div class="apipv6-actions"><button type="button" id="apipv6-check" class="btn btn-default">立即检查</button><button type="button" id="apipv6-repair" class="btn btn-primary">立即修复</button></div>
    </section>

    <section class="apipv6-panel">
        <h2>IPv6 详细信息</h2>
        <div style="overflow-x:auto">
            <table class="apipv6-table">
                <thead><tr><th>IPv6 地址</th><th>类型</th><th>状态</th><th>前缀长度</th><th>Preferred 生命周期</th><th>Valid 生命周期</th><th>Temporary</th></tr></thead>
                <tbody id="apipv6-address-rows"></tbody>
            </table>
        </div>
        <div class="apipv6-grid" style="margin-top:12px">
            <div>br0 disable_ipv6：<strong id="apipv6-disable">—</strong></div>
            <div>br0 accept_ra：<strong id="apipv6-accept-ra">—</strong></div>
            <div>br0 autoconf：<strong id="apipv6-autoconf">—</strong></div>
        </div>
    </section>

    <section class="apipv6-panel">
        <h2>自动修复设置</h2>
        <div class="apipv6-field"><label for="apipv6-enabled">启用开机自动修复与插件任务</label><input id="apipv6-enabled" type="checkbox"></div>
        <div class="apipv6-field"><label for="apipv6-delay">开机修复延迟（0–180 秒）</label><input id="apipv6-delay" type="number" min="0" max="180" value="30"></div>
        <div class="apipv6-field"><label for="apipv6-health-enabled">周期健康检查</label><input id="apipv6-health-enabled" type="checkbox"></div>
        <div class="apipv6-field"><label for="apipv6-interval">检查间隔（5–60 分钟）</label><input id="apipv6-interval" type="number" min="5" max="60" value="15"></div>
        <div class="apipv6-field"><label for="apipv6-repair-on-error">检测到地址 / 路由 / 参数异常时自动修复</label><input id="apipv6-repair-on-error" type="checkbox"></div>
        <p class="apipv6-note">周期检查只读取状态。启用“异常自动修复”后，才会在 AP 模式下更改 br0 的三个 SLAAC sysctl 值。公网 Ping 失败不会单独触发修复。</p>
        <div class="apipv6-actions"><button type="button" id="apipv6-save" class="btn btn-primary">保存设置</button></div>
    </section>

    <section class="apipv6-panel">
        <h2>日志与诊断</h2>
        <div class="apipv6-grid">
            <div>最近健康检查：<strong id="apipv6-last-check">—</strong></div>
            <div>最近成功修复：<strong id="apipv6-last-repair">—</strong></div>
            <div>最近修复失败原因：<strong id="apipv6-last-failure">—</strong></div>
            <div>旧启动脚本迁移：<strong id="apipv6-migration">—</strong></div>
        </div>
        <div class="apipv6-actions"><button type="button" id="apipv6-refresh-log" class="btn btn-default">刷新日志</button><button type="button" id="apipv6-clear-log" class="btn btn-default">清理插件日志</button></div>
        <textarea id="apipv6-log" readonly aria-label="AP IPv6 Manager 日志"></textarea>
        <div id="apipv6-message" role="status" aria-live="polite"></div>
    </section>
</div>
</body>
</html>
