"use strict";
const assert = require("assert");
const fs = require("fs");
const vm = require("vm");
const html = fs.readFileSync("webs/Module_apipv6.asp", "utf8");
const match = html.match(/<script>([\s\S]*?)<\/script>/);
assert(match, "inline page controller is present");
const controller = match[1];
assert(!/\.innerHTML\b|document\.write\s*\(|\beval\s*\(/.test(controller), "dynamic router data is never executed or inserted as HTML");

function Element() {
    this.children = [];
    this.firstChild = null;
    this.textContent = "";
    this.style = {};
    this.value = "";
    this.checked = false;
}
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
const context = { window: window, document: document, XMLHttpRequest: function () {}, Date: Date, JSON: JSON, Object: Object, String: String, Math: Math };
new vm.Script(controller, { filename: "Module_apipv6.asp inline script" });
vm.runInNewContext(controller, context);

const hooks = window.apipv6TestHooks;
assert.strictEqual(hooks.parseApiResponse({ result: "{\"ok\":true}" }).ok, true, "API JSON strings are decoded");
assert.strictEqual(hooks.parseApiResponse({ result: { ok: true } }).ok, true, "API JSON objects are retained");
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
console.log("Web controller syntax, API parsing, status mapping, and safe text rendering passed.");
