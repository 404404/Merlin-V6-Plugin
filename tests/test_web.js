"use strict";
const assert = require("assert");
const fs = require("fs");
const vm = require("vm");
const html = fs.readFileSync("webs/Module_apipv6.asp", "utf8");
const match = html.match(/<script>([\s\S]*?)<\/script>/);
assert(match, "inline page controller is present");
const controller = match[1];
for (const resource of ["/index_style.css", "/form_style.css", "/usp_style.css", "/res/softcenter.css", "/state.js", "/res/softcenter.js"]) {
    assert(html.includes('"' + resource + '"'), "uses firmware resource " + resource);
}
for (const id of ["TopBanner", "mainMenu", "subMenu", "tabMenu", "FormTitle", "footer", "Loading", "hidden_frame"]) {
    assert(html.includes('id="' + id + '"'), "has native UI container " + id);
}
assert(html.includes('skin=\'<% nvram_get("sc_skin"); %>\''), "inherits KoolShare skin");
assert(!/bootstrap|body\s*\{/.test(html), "does not replace the firmware body style or load Bootstrap");
const ids = Array.from(html.matchAll(/\bid="([^"]+)"/g), match => match[1]);
assert.strictEqual(new Set(ids).size, ids.length, "all native and plugin element IDs are unique");
assert(!/\.innerHTML\b|document\.write\s*\(|\beval\s*\(/.test(controller), "dynamic router data is never executed or inserted as HTML");

function Element() {
    this.children = [];
    this.firstChild = null;
    this.textContent = "";
    this.style = {};
    this.value = "";
    this.checked = false;
    this.events = {};
}
Element.prototype.addEventListener = function (name, fn) { this.events[name] = fn; };
Element.prototype.appendChild = function (child) {
    this.children.push(child);
    this.firstChild = this.children[0] || null;
    return child;
};
Element.prototype.removeChild = function (child) {
    this.children = this.children.filter(function (candidate) { return candidate !== child; });
    this.firstChild = this.children[0] || null;
};

const elements = Object.create(null);
const document = {
    getElementById: function (id) { return elements[id] || (elements[id] = new Element()); },
    createElement: function () { return new Element(); }
};
const window = {
    setTimeout: function () { return 1; },
    clearTimeout: function () {},
    setInterval: function () { return 1; },
    confirm: function () { return false; }
};
const requests = [];
function XHR() { requests.push(this); }
XHR.prototype.open = function () {};
XHR.prototype.setRequestHeader = function () {};
XHR.prototype.send = function (body) { this.payload = JSON.parse(body); };
let menusShown = 0;
const tabtitle = [["", "软件中心"]];
const tablink = [["", "Module_Softcenter.asp"]];
const context = { window: window, document: document, XMLHttpRequest: XHR, Date: Date, JSON: JSON, Object: Object, String: String, Math: Math,
    tabtitle, tablink, show_menu: function (hook) { menusShown++; hook(); } };
new vm.Script(controller, { filename: "Module_apipv6.asp inline script" });
vm.runInNewContext(controller, context);

const hooks = window.apipv6TestHooks;
assert.strictEqual(hooks.parseApiResponse({ result: "{\"ok\":true}" }).ok, true, "API JSON strings are decoded");
assert.strictEqual(hooks.parseApiResponse({ result: { ok: true } }).ok, true, "API JSON objects are retained");
const wireValue = { ok: true, log: '中文 "quote" \\ path\r\nnext\tline' };
const encoded = "apipv6-hex-v1:" + Buffer.from(JSON.stringify(wireValue), "utf8").toString("hex");
assert.deepStrictEqual(JSON.parse(JSON.stringify(hooks.parseApiResponse(JSON.parse('{"result":"' + encoded + '"}')))), wireValue, "legacy raw envelope safely carries UTF-8 JSON");
assert.throws(() => JSON.parse('{"result":"' + JSON.stringify(wireValue) + '"}'), "RC7 raw JSON breaks the actual httpdb envelope");
for (const value of ["apipv6-hex-v1:", "apipv6-hex-v1:a", "apipv6-hex-v1:zz", "apipv6-hex-v1:ff"]) assert(hooks.parseApiResponse({ result: value }).error, "malformed encoded response is rejected");
assert(hooks.parseApiResponse({ result: -2 }).error, "httpdb method-not-found codes are errors");
assert(hooks.parseApiResponse({ result: "" }).error, "empty backend responses are errors");
assert.strictEqual(hooks.statusClass("normal"), "state-normal", "normal status uses its fixed class");
assert.strictEqual(hooks.statusClass("unexpected <img>"), "state-detection_error", "unknown status cannot inject a CSS class");

const hostileText = "<img src=x onerror=alert(1)>";
hooks.renderDetails({
    addresses: [{ address: hostileText, type: "global_unicast", state: "preferred", prefix_length: "64", preferred_lifetime: "10sec", valid_lifetime: "20sec", temporary: false }],
    sysctl: { disable_ipv6: "0", accept_ra: "2", autoconf: "1" }
});
const cells = document.getElementById("apipv6-address-rows").children[0].children;
assert.strictEqual(cells[0].textContent, hostileText, "untrusted IPv6 text is displayed as text");
assert.strictEqual(cells[0].children.length, 0, "untrusted IPv6 text does not become a DOM node");
window.initApipv6();
assert.strictEqual(menusShown, 1, "initialization invokes the firmware menu builder");
assert.strictEqual(tabtitle[0][1], "AP IPv6 管理");
assert.strictEqual(tablink[0][1], "Module_apipv6.asp");
assert.strictEqual(requests.length, 2, "initial status and log requests are sent");
assert.notStrictEqual(requests[0].payload.id, requests[1].payload.id, "simultaneous requests have distinct IDs");
requests[0].ontimeout();
assert.strictEqual(document.getElementById("apipv6-health").textContent, "读取失败", "timeout never leaves status reading forever");
const timeoutMessage = document.getElementById("apipv6-message").textContent;
requests[0].onerror();
assert.strictEqual(document.getElementById("apipv6-message").textContent, timeoutMessage, "only one completion per request");
document.getElementById("apipv6-save").events.click();
const save = requests[2].payload;
assert.strictEqual(Object.keys(save.fields).length, 5);
Object.keys(save.fields).forEach(key => assert(key.startsWith("apipv6_websubmit_" + save.id + "_")));
requests[2].status = 200;
requests[2].responseText = "not JSON";
requests[2].onload();
assert(document.getElementById("apipv6-message").textContent.includes("HTTP 200"));
console.log("Web controller syntax, API parsing, safe text rendering, request scoping, timeout and invalid-response handling passed.");
