"use strict";
// Exercise the real page -> HTTP dispatcher -> installed shell -> HTTP callback.
// Protocol reference: koolshare/rogsoft softcenter/scripts/base.sh (ID=$1,
// http_response POSTs the raw result to /_resp/$ID). The dispatcher prepends ID
// and persists fields before execution, just as KoolShare httpdb does.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const os = require("os");
const http = require("http");
const vm = require("vm");
const { execFile } = require("child_process");
const { promisify } = require("util");
const exec = promisify(execFile);
const root = path.resolve(__dirname, "..");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "apipv6-http-test-"));
const ks = path.join(temp, "koolshare");
const sysctl = path.join(temp, "sysctl");
const wrongShell = path.join(temp, "broadcom");
const env = Object.assign({}, process.env, {
    PATH: wrongShell + ":" + path.join(root, "tests/mocks") + ":" + process.env.PATH,
    APIPV6_KS_DIR: ks, APIPV6_RUN_DIR: path.join(ks, "var/apipv6"),
    APIPV6_CONFIG_FILE: path.join(ks, "configs/apipv6.conf"),
    APIPV6_SYSCTL_ROOT: sysctl, APIPV6_TMP_ROOT: path.join(temp, "tmp"),
    MOCK_DBUS_FILE: path.join(temp, "dbus.values"), MOCK_IP_COUNTER_FILE: path.join(temp, "ip-count"),
    MOCK_CRU_LOG: path.join(temp, "cru.log"), MOCK_SW_MODE: "3", MOCK_WLC_PSTA: "0",
    MOCK_IP_SCENARIO: "good", MOCK_PING: "success", APIPV6_TEST_NO_SLEEP: "1", APIPV6_RA_WAIT_SECONDS: "0"
});
const dbus = (command, value) => exec(path.join(root, "tests/mocks/dbus"), [command, value || ""], { env });
const pending = new Map();
const callbacks = new Map();
const requests = [];
const processes = [];
const clients = new Set();
const timers = new Set();
let origin;
const server = http.createServer(async (req, res) => {
    let body = "";
    for await (const chunk of req) body += chunk;
    if (req.url.startsWith("/_resp/")) {
        const id = req.url.slice("/_resp/".length);
        callbacks.set(id, (callbacks.get(id) || 0) + 1);
        const reply = pending.get(id);
        if (!reply) { res.writeHead(404).end(); return; }
        pending.delete(id);
        clearTimeout(reply.timer);
        // httpdb wraps callback text in the result field of the original request.
        reply.res.writeHead(200, { "Content-Type": "application/json" });
        reply.res.end(JSON.stringify({ id: Number(id), result: body }));
        res.writeHead(200).end("OK");
        return;
    }
    if (req.url !== "/_api/") { res.writeHead(404).end(); return; }
    try {
        const payload = JSON.parse(body);
        assert.strictEqual(payload.method, "apipv6_config.sh");
        assert(Number.isSafeInteger(payload.id) && payload.id >= 0);
        const id = String(payload.id);
        assert(!pending.has(id), "request IDs must be unique");
        requests.push(payload);
        // Use real DBus mock processes; do not inject fields as shell variables.
        for (const [key, value] of Object.entries(payload.fields || {})) await dbus("set", key + "=" + value);
        const timer = setTimeout(() => {
            pending.delete(id);
            if (!res.writableEnded) res.writeHead(504).end(JSON.stringify({ error: "Missing KoolShare callback for ID " + id }));
        }, 10000);
        pending.set(id, { res, timer });
        processes.push(exec(path.join(ks, "scripts/apipv6_config.sh"), [id, ...payload.params], { env })
            .catch(error => { if (error.signal) throw error; return error; }));
    } catch (error) { res.writeHead(500).end(JSON.stringify({ error: error.message })); }
});
class Element {
    constructor() { this.children = []; this.firstChild = null; this.textContent = ""; this.style = {}; this.value = ""; this.checked = false; this.events = {}; }
    appendChild(child) { this.children.push(child); this.firstChild = this.children[0]; return child; }
    removeChild(child) { this.children = this.children.filter(value => value !== child); this.firstChild = this.children[0] || null; }
    addEventListener(name, fn) { this.events[name] = fn; }
}
class XHR {
    open(method, url) { this.method = method; this.url = url; }
    setRequestHeader() {}
    send(body) {
        const request = http.request(new URL(this.url, origin), { method: this.method, headers: { "Content-Type": "application/json" } }, response => {
            this.status = response.statusCode;
            this.responseText = "";
            response.on("data", chunk => { this.responseText += chunk; });
            response.on("end", () => { clients.delete(request); if (this.onload) this.onload(); });
        });
        clients.add(request);
        request.setTimeout(this.timeout, () => { request.destroy(); if (this.ontimeout) this.ontimeout(); });
        request.on("error", () => { clients.delete(request); if (this.onerror) this.onerror(); });
        request.end(body);
    }
}
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate, label) {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) { if (predicate()) return; await pause(25); }
    throw new Error("Timed out: " + label);
}
async function request(params, fields = {}, extraEnv = {}) {
    Object.assign(env, extraEnv);
    const id = 100000000 + requests.length;
    const staged = {};
    for (const [key, value] of Object.entries(fields)) staged["apipv6_websubmit_" + id + "_" + key] = value;
    return new Promise((resolve, reject) => {
        const req = http.request(origin + "/_api/", { method: "POST" }, res => {
            let body = "";
            res.on("data", chunk => { body += chunk; });
            res.on("end", () => { try { assert.strictEqual(res.statusCode, 200, body); resolve(JSON.parse(JSON.parse(body).result)); } catch (e) { reject(e); } });
        });
        req.on("error", reject);
        req.end(JSON.stringify({ id, method: "apipv6_config.sh", params, fields: staged }));
    });
}
(async () => {
    fs.mkdirSync(wrongShell, { recursive: true });
    fs.mkdirSync(env.APIPV6_TMP_ROOT, { recursive: true });
    // Reproduce Broadcom's sh memory utility, including its misleading exit 0.
    fs.writeFileSync(path.join(wrongShell, "sh"), '#!/bin/sh\nprintf "wrong sh invoked\\n" >> "$APIPV6_TMP_ROOT/wrong-sh"\nexit 0\n', { mode: 0o755 });
    fs.mkdirSync(path.join(sysctl, "br0"), { recursive: true });
    for (const [name, value] of Object.entries({ disable_ipv6: "0", autoconf: "1", accept_ra: "2" })) fs.writeFileSync(path.join(sysctl, "br0", name), value + "\n");
    fs.writeFileSync(env.MOCK_DBUS_FILE, "other_plugin_sentinel=preserve\n");
    const source = path.join(temp, "source");
    fs.mkdirSync(source);
    for (const file of ["install.sh", "uninstall.sh", "rollback.sh", "config.json.js", "scripts", "webs", "res", "init.d"]) fs.cpSync(path.join(root, file), path.join(source, file), { recursive: true });
    fs.writeFileSync(path.join(source, ".valid"), "hnd\n");
    env.APIPV6_SOURCE_DIR = source;
    await exec("/bin/sh", [path.join(source, "install.sh")], { env });
    assert(!fs.existsSync(path.join(env.APIPV6_TMP_ROOT, "wrong-sh")), "installer must not execute PATH sh");
    // An invalid script must fail before any plugin files/metadata change.
    const installed = fs.readFileSync(path.join(ks, "scripts/apipv6_config.sh"));
    fs.appendFileSync(path.join(source, "scripts/apipv6_config.sh"), "\nif then\n");
    await assert.rejects(exec("/bin/sh", [path.join(source, "install.sh")], { env }), error =>
        error.code !== 0 && error.stdout.includes("Shell 语法检查失败"));
    assert(fs.readFileSync(path.join(ks, "scripts/apipv6_config.sh")).equals(installed));
    assert(!fs.existsSync(path.join(env.APIPV6_TMP_ROOT, "wrong-sh")));
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    origin = "http://127.0.0.1:" + server.address().port;
    env.APIPV6_TEST_CURL_ORIGIN = origin;
    // Source unmodified upstream base.sh. Verify its actual curl command and
    // relocate only the HTTP transport endpoint to our ephemeral local server.
    fs.copyFileSync(path.join(root, "tests/fixtures/koolshare-base.sh"), path.join(ks, "scripts/base.sh"));
    fs.writeFileSync(path.join(wrongShell, "curl"), '#!/bin/sh\n' +
        '[ "$#" -eq 5 ] && [ "$1" = -X ] && [ "$2" = POST ] && [ "$3" = -d ] || exit 90\n' +
        'case "$5" in http://127.0.0.1:3030/_resp/*) ;; *) exit 91 ;; esac\n' +
        'endpoint=${5#http://127.0.0.1:3030}\n' +
        'exec /usr/bin/curl --noproxy "*" --fail --silent --show-error -X POST -d "$4" "$APIPV6_TEST_CURL_ORIGIN$endpoint"\n', { mode: 0o755 });
    const elements = {};
    const el = id => elements[id] || (elements[id] = new Element());
    const window = { confirm: () => true, setInterval: () => 1,
        setTimeout: (fn, ms) => { const timer = setTimeout(() => { timers.delete(timer); fn(); }, ms); timers.add(timer); return timer; },
        clearTimeout: timer => { clearTimeout(timer); timers.delete(timer); } };
    const controller = fs.readFileSync(path.join(ks, "webs/Module_apipv6.asp"), "utf8").match(/<script>([\s\S]*?)<\/script>/)[1];
    let menusShown = 0;
    vm.runInNewContext(controller, { window, document: { getElementById: el, createElement: () => new Element() }, XMLHttpRequest: XHR, Date, JSON, Object, String, Math,
        tabtitle: [["", "软件中心"]], tablink: [["", "Module_Softcenter.asp"]], show_menu: hook => { menusShown++; hook(); } });
    window.initApipv6();
    assert.strictEqual(menusShown, 1, "native menu initializes before API requests");
    await until(() => el("apipv6-primary").textContent === "240a:42cc:1001:7141::10", "page initial status through callback");
    await until(() => requests.length >= 2 && pending.size === 0, "initial log callback");
    assert(el("apipv6-mode").textContent.includes("AP 模式"));
    assert(el("apipv6-address-rows").children.length > 1);
    el("apipv6-delay").value = "0";
    el("apipv6-interval").value = "10";
    el("apipv6-save").events.click();
    await until(() => el("apipv6-message").textContent.includes("配置已保存"), "valid save via staged fields");
    await until(() => el("apipv6-delay").value === "0", "zero delay stays zero after refresh");
    assert.strictEqual((await dbus("get", "apipv6_start_delay")).stdout.trim(), "0");
    const settings = { enabled: "1", start_delay: "20", health_enabled: "1", health_interval: "1", repair_on_error: "1" };
    const before = fs.readFileSync(env.MOCK_DBUS_FILE, "utf8").split("\n").filter(row => !row.startsWith("apipv6_websubmit_")).sort().join("\n");
    assert.strictEqual((await request(["save_config", "web_submit"], settings)).ok, false);
    assert.strictEqual(fs.readFileSync(env.MOCK_DBUS_FILE, "utf8").split("\n").sort().join("\n"), before, "invalid fields cannot alter live DBus values");
    settings.health_interval = "10";
    assert.strictEqual((await request(["save_config", "web_submit"], settings, { MOCK_CRU_FAIL: "1" })).ok, false);
    assert.strictEqual((await dbus("get", "apipv6_start_delay")).stdout.trim(), "0", "failed schedule restores live config");
    delete env.MOCK_CRU_FAIL;
    assert.strictEqual((await request(["save_config", "web_submit"], {})).ok, false, "missing staged fields fail closed");
    assert.strictEqual((await request(["check", "web_submit"])).health, "normal");
    const check = await request(["check", "--scheduled"], {}, { MOCK_IP_SCENARIO: "no_address" });
    assert.strictEqual(check.health, "address_error", "unhealthy check still calls back with JSON");
    env.MOCK_IP_SCENARIO = "good";
    assert.strictEqual((await request(["status"])).health, "normal", "API status always JSON even without --json");
    for (const op of ["repair", "boot", "__web_repair", "not_an_operation"]) assert.strictEqual((await request([op])).ok, false);
    fs.writeFileSync(path.join(sysctl, "br0/disable_ipv6"), "1\n");
    el("apipv6-repair").events.click();
    await until(() => el("apipv6-message").textContent.includes("修复任务结束：success"), "async repair and polling callbacks");
    assert.strictEqual(fs.readFileSync(path.join(sysctl, "br0/disable_ipv6"), "utf8").trim(), "0");
    await until(() => el("apipv6-log").value.includes("Repair success"), "log refresh through HTTP");
    await until(() => pending.size === 0, "repair refreshes complete");
    el("apipv6-clear-log").events.click();
    await until(() => el("apipv6-message").textContent === "日志已清理。", "clear log callback");
    assert.strictEqual(fs.readFileSync(path.join(env.APIPV6_RUN_DIR, "apipv6.log"), "utf8"), "");
    await Promise.all(processes);
    assert.strictEqual(callbacks.size, requests.length, "each HTTP request has a callback");
    for (const count of callbacks.values()) assert.strictEqual(count, 1, "exactly one callback per ID");
    for (const payload of requests) for (const key of Object.keys(payload.fields)) assert(key.startsWith("apipv6_websubmit_" + payload.id + "_"), "never submit live settings as HTTP fields");
    assert(!fs.readFileSync(env.MOCK_DBUS_FILE, "utf8").includes("apipv6_websubmit_"), "staging fields cleaned on success and failure");
    assert.strictEqual((await dbus("get", "other_plugin_sentinel")).stdout.trim(), "preserve");
    assert(!fs.existsSync(path.join(env.APIPV6_TMP_ROOT, "wrong-sh")));
    for (const timer of timers) clearTimeout(timer);
    console.log("Installed plugin HTTP tests passed: numeric ID, base.sh callback, page status/logs/save/check/repair/poll/clear, validation rollback, scoped fields, and shadowed sh rejection.");
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
    for (const timer of timers) clearTimeout(timer);
    for (const reply of pending.values()) { clearTimeout(reply.timer); reply.res.destroy(); }
    for (const request of clients) request.destroy();
    await Promise.all(processes);
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(temp, { recursive: true, force: true });
});
