/* Read-only EasyTier node view. No configuration or network credentials. */
(function(root) {
    "use strict";
    var messages = {
        stopped: "服务未运行", cli_missing: "缺少配套查询工具，请完整安装插件包",
        helper_missing: "缺少节点查询脚本，请完整安装插件包",
        rpc_unsupported: "管理接口未使用受支持的本机地址或端口",
        rpc_unverified: "无法确认管理端口属于当前 EasyTier 进程",
        process_unverified: "无法核实当前 EasyTier 进程", process_changed: "服务状态已变化，请稍后刷新",
        busy: "已有查询正在进行，请稍后刷新", timeout: "管理接口查询超时，服务仍可继续运行",
        query_failed: "查询工具执行失败或与当前核心不兼容，请稍后手动重试",
        invalid_output: "查询结果为空或超过大小限制", storage_error: "无法建立查询缓存",
        invalid_json: "查询结果格式不兼容", request_failed: "节点信息请求失败"
    };
    function text(value, fallback) {
        return typeof value === "string" && /\S/.test(value) ? value.slice(0, 256) : (fallback || "—");
    }
    function normalize(rows) {
        if (!Array.isArray(rows) || rows.length > 512) throw new Error("invalid rows");
        var localCount = 0;
        var result = rows.map(function(row) {
            if (!row || typeof row !== "object" || typeof row.cost !== "string" || typeof row.hostname !== "string") {
                throw new Error("invalid row");
            }
            var local = row.cost === "Local";
            var direct = /^p2p$/i.test(row.cost);
            if (local) localCount++;
            return {
                local: local, hostname: text(row.hostname), id: text(row.id),
                ip: text(row.cidr || row.ipv4),
                connection: local ? "本机" : (direct ? "直连" : text(row.cost).replace(/^relay/i, "中继")),
                latency: text(row.lat_ms), loss: direct ? text(row.loss_rate) : "—",
                rx: direct ? text(row.rx_bytes) : "—", tx: direct ? text(row.tx_bytes) : "—",
                tunnel: text(row.tunnel_proto), version: text(row.version, "未知")
            };
        });
        // Never use a remote peer's version as the local core's version.
        if (localCount !== 1) throw new Error("missing or ambiguous local node");
        return result;
    }
    function element(id) { return root.document.getElementById(id); }
    function setText(id, value) { element(id).textContent = value; }
    function render(envelope, rows) {
        var body = element("easytier_nodes_body");
        while (body.firstChild) body.removeChild(body.firstChild);
        var version = envelope.core_version ? "v" + envelope.core_version + "（文件指纹确认）" : "未知";
        if (envelope.state !== "ready") {
            setText("easytier_nodes_message", messages[envelope.state] || messages.request_failed);
            setText("easytier_core_version", version);
            return;
        }
        var local = rows.filter(function(row) { return row.local; })[0];
        if (local && local.version !== "未知" && !/^unknown$/i.test(local.version)) {
            version = local.version + "（本机 RPC）";
        }
        setText("easytier_core_version", version);
        rows.forEach(function(row) {
            var tr = root.document.createElement("tr");
            [row.hostname, row.ip, row.connection, /^[0-9]+(\.[0-9]+)?$/.test(row.latency) ? row.latency + " ms" : "—",
                row.loss, row.rx, row.tx, row.tunnel, row.version].forEach(function(value) {
                var td = root.document.createElement("td");
                td.textContent = value; // Peer names/versions are untrusted network input.
                tr.appendChild(td);
            });
            body.appendChild(tr);
        });
        var collected = new Date(envelope.collected_at * 1000);
        setText("easytier_nodes_message", "本机及 " + (rows.length - 1) + " 个节点 · 更新于 " + collected.toLocaleTimeString() + " · 流量为连接累计值");
    }
    var mounted = false;
    function mount() {
        if (mounted) return;
        mounted = true;
        var pending = false, timer = null, request = null, closed = false;
        function schedule() {
            if (!closed && element("easytier_nodes_auto").checked) timer = root.setTimeout(function() { refresh(false); }, 15000);
        }
        function refresh(manual) {
            if (closed || pending) return;
            root.clearTimeout(timer);
            if ((!manual && root.document.hidden) || (!manual && !element("easytier_nodes_auto").checked)) {
                schedule(); return;
            }
            pending = true;
            element("easytier_nodes_refresh").disabled = true;
            setText("easytier_nodes_message", "正在读取节点信息…");
            request = root.jQuery.ajax({
                type: "POST", url: "/_api/", dataType: "json", timeout: 8000,
                data: JSON.stringify({id: Math.floor(Math.random() * 100000000), method: "easytier_config.sh", params: ["nodes"], fields: ""}),
                success: function(response) {
                    var envelope = {state: "invalid_json"};
                    try {
                        envelope = typeof response.result === "string" ? JSON.parse(response.result) : response.result;
                        if (!envelope || typeof envelope.state !== "string") throw new Error("invalid envelope");
                        // Decode UTF-8 without requiring TextDecoder on older browsers.
                        var rows = envelope.state === "ready" ? normalize(JSON.parse(decodeURIComponent(escape(root.atob(envelope.payload))))) : [];
                        render(envelope, rows);
                    } catch (ignore) {
                        render({state: "invalid_json", core_version: envelope && envelope.core_version}, []);
                    }
                },
                error: function() { render({state: "request_failed"}, []); },
                complete: function() {
                    pending = false; request = null;
                    element("easytier_nodes_refresh").disabled = false;
                    schedule();
                }
            });
        }
        element("easytier_nodes_refresh").onclick = function() { refresh(true); };
        element("easytier_nodes_auto").onchange = function() {
            root.clearTimeout(timer);
            if (this.checked) refresh(false);
        };
        root.addEventListener("beforeunload", function() {
            closed = true; root.clearTimeout(timer);
            if (request) request.abort();
        });
        refresh(false);
    }
    var api = {normalize: normalize, render: render, mount: mount};
    if (typeof module !== "undefined" && module.exports) module.exports = api;
    root.EasyTierNodes = api;
}(typeof window !== "undefined" ? window : globalThis));
