`koolshare-base.sh` is the unmodified KoolShare base.sh retrieved on 2026-10-28:
https://raw.githubusercontent.com/koolshare/rogsoft/master/softcenter/softcenter/scripts/base.sh

The HTTP integration test sources this fixture as the installed `scripts/base.sh`.
A test-only curl wrapper verifies its original `http://127.0.0.1:3030/_resp/ID`
endpoint and forwards that request to an ephemeral loopback port. Production
callback behavior and the fixture are not rewritten.

The WebUI layout follows `webs/Module_easytier.asp` on `origin/EasyTier-Merlin`
(read-only reference). It uses the existing Merlin `state.js` show_menu hook,
TopBanner/mainMenu/subMenu/tabMenu/footer containers, FormTitle/FormTable,
button_gen/input_3_table, and KoolShare `sc_skin` / softcenter.css.

The legacy response envelope is derived from `show_shell_resp()` in:
https://github.com/thesadboy/httpdb/blob/d7b6bffaa9e6b3df452d3c2fc46459fde8be02ba/src/http.c
It formats `{"result": "%s"}` without escaping callback text, matching the
RC7 failure reported by the tester. Do not use JSON.stringify to simulate this
legacy envelope. The integration test also checks an escaping implementation.

RC8 transport: `apipv6-hex-v1:` followed by lowercase hex of the UTF-8 JSON
bytes, no newlines. Encoding uses the existing awk dependency under LC_ALL=C;
the page validates framing, decodes bytes as UTF-8 and then parses JSON. CLI
output stays JSON. The callback uses curl's existing -d @file support so the
encoded log body does not have to fit into one command-line argument.
