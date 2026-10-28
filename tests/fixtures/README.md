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
