"use strict";
const assert = require("assert");
const fs = require("fs");
const vm = require("vm");
class Element {
    constructor() { this.children = []; this.textContent = ""; this.checked = true; }
    get firstChild() { return this.children[0]; }
    appendChild(child) { this.children.push(child); }
    removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
    set innerHTML(value) { throw new Error("Unsafe innerHTML: " + value); }
}
const elements = {};
const requests = [];
const timers = [];
const root = {
    document: {hidden: false, getElementById: id => elements[id] || (elements[id] = new Element()), createElement: () => new Element()},
    jQuery: {ajax: options => { requests.push(options); return {abort() {}}; }},
    atob: value => Buffer.from(value, "base64").toString("binary"),
    setTimeout: callback => {timers.push(callback); return timers.length;}, clearTimeout() {}, addEventListener() {}
};
vm.runInNewContext(fs.readFileSync(require.resolve("../res/easytier_nodes.js"), "utf8"), {window: root, escape});
const api = root.EasyTierNodes;
const peers = [
    {hostname: "AX56U", cost: "Local", version: "2.5.3", cidr: "192.0.2.1/24", lat_ms: "-"},
    {hostname: '<img src=x onerror="alert(1)">', cost: "p2p", version: "2.6.4", lat_ms: "12.30", loss_rate: "0.1%", rx_bytes: "1 MB", tx_bytes: "2 MB"}
];
const rows = api.normalize(peers);
assert.strictEqual(rows[1].connection, "直连");
const relayRows = api.normalize([peers[0], {...peers[1], cost: "relay(2)", rx_bytes: "0 B", loss_rate: "0.0%"}]);
assert.strictEqual(relayRows[1].connection, "中继(2)");
assert.strictEqual(relayRows[1].loss, "—");
assert.strictEqual(relayRows[1].rx, "—");
assert.throws(() => api.normalize([peers[1]]));
assert.throws(() => api.normalize([peers[0], peers[0]]));
assert.throws(() => api.normalize({config: "PRIVATE"}));
api.render({state: "ready", core_version: "", collected_at: 100}, rows);
assert.strictEqual(elements.easytier_core_version.textContent, "2.5.3（本机 RPC）");
assert.strictEqual(elements.easytier_nodes_body.children[1].children[0].textContent, peers[1].hostname);
api.render({state: "timeout"}, []);
assert.strictEqual(elements.easytier_nodes_body.children.length, 0);
assert.strictEqual(elements.easytier_core_version.textContent, "未知");
api.render({state: "stopped", core_version: "2.6.4"}, []);
assert.strictEqual(elements.easytier_core_version.textContent, "v2.6.4（文件指纹确认）");
api.mount();
assert.strictEqual(requests.length, 1);
assert.deepStrictEqual(JSON.parse(requests[0].data).params, ["nodes"]);
elements.easytier_nodes_refresh.onclick();
assert.strictEqual(requests.length, 1); // One in-flight request at a time.
const payload = Buffer.from(JSON.stringify(peers), "utf8").toString("base64");
requests[0].success({result: JSON.stringify({state: "ready", payload, collected_at: 100})});
requests[0].complete();
assert.strictEqual(elements.easytier_core_version.textContent, "2.5.3（本机 RPC）");
root.document.hidden = true;
timers.pop()();
assert.strictEqual(requests.length, 1); // Hidden pages do not poll.
root.document.hidden = false;
elements.easytier_nodes_refresh.onclick();
requests[1].success({result: '{"state":"ready","payload":"not-json"}'});
requests[1].complete();
assert.strictEqual(elements.easytier_nodes_body.children.length, 0);
assert.strictEqual(elements.easytier_core_version.textContent, "未知");
console.log("Node UI schema, local-version attribution, XSS, stale-state, polling and response tests passed.");
