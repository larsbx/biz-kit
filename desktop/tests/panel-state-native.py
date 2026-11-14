#!/usr/bin/env python3
"""Linux Tauri acceptance: real WebKit, IPC, file reads, and unsaved editors.

Build: npm run tauri build -- --debug --no-bundle
Run:   xvfb-run -a -s '-screen 0 1920x1080x24' python3 tests/panel-state-native.py src-tauri/target/debug/biz-kit
Needs tauri-driver 2.0.4 and WebKitWebDriver on PATH. Uses disposable XDG dirs
and a synthetic config; never touches an operator's files or credentials.
"""
import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading


from native_webdriver import native_session, until


@contextmanager
def procurement_fixture(tls):
    if tls is None:
        yield None
        return

    unexpected = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/":
                self.send_response(303)
                self.send_header("Location", "/requests")
                self.end_headers()
                return
            if self.path in {"/foreign", "/popup"}:
                unexpected.append(self.path)
            port = self.server.server_port
            html = (
                '<h1>Procurement HTTPS fixture</h1>'
                '<a id="orders" href="/orders">Orders</a> '
                f'<a id="foreign" href="https://localhost:{port}/foreign">Foreign origin</a> '
                '<a id="popup" target="_blank" href="/popup">New window</a>'
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)

        def log_message(self, *_):
            pass

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(*tls)
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"https://127.0.0.1:{server.server_port}", unexpected
        finally:
            server.shutdown()
            thread.join()


def run(binary, session_timeout=60, service_owner_fixture=False, procurement_tls=None):
    with tempfile.TemporaryDirectory(prefix="biz-kit-panels-") as tmp, procurement_fixture(procurement_tls) as procurement:
        root = Path(tmp)
        fixture = root / "app.json"
        original = '{"token":"original-native-fixture"}'
        fixture.write_text(original)
        scripts = root / "scripts"
        scripts.mkdir()
        applied = root / "script-applied"
        (scripts / "fixture.sh").write_text(
            "#!/usr/bin/env bash\n# Native dry-run and apply fixture.\n"
            "case \"$1\" in\n"
            "--dry-run) echo 'dry-run confirmed';;\n"
            f"--apply) echo applied > '{applied}'; echo 'apply confirmed';;\n"
            "*) echo 'explicit flag required' >&2; exit 64;;\nesac\n"
        )
        service_file = root / "service-owned.json"
        service_original = '{"service":"original"}'
        if service_owner_fixture:
            service_file.write_text(service_original)
            service_file.chmod(0o660)
            subprocess.run(["sudo", "-n", "chown", f"0:{os.getgid()}", str(service_file)], check=True)
            assert service_file.stat().st_uid == 0 and os.getuid() != 0, "ownership fixture needs an ordinary editing user"
        config = root / "config" / "biz-kit"
        config.mkdir(parents=True)
        config_path = config / "config.json"
        config_data = {
            "hosts": [{"name": "local", "label": "Local fixture", "ssh": None}],
            "configs": [{"path": str(fixture), "label": "Native fixture"}],
            "scriptsDir": str(root / "scripts"),
        }
        config_path.write_text(json.dumps(config_data))
        env = {**os.environ, "XDG_CONFIG_HOME": str(root / "config"),
               "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache")}
        with (
            (root / "driver.log").open("w+") as log,
            native_session(binary, env, log, session_timeout) as (request, base),
        ):
            try:
                def js(script, *args):
                    return request("POST", base + "/execute/sync", {"script": script, "args": list(args)})

                def click(selector):
                    element = request("POST", base + "/element", {"using": "css selector", "value": selector})
                    request("POST", base + f'/element/{element["element-6066-11e4-a52e-4f735466cecf"]}/click', {})

                def intact():
                    return js("""return window.editors.every((e,i) => e.isConnected &&
                      e === window.panels[i].querySelector('textarea') &&
                      e.value === JSON.stringify({token:'native-unsaved-secret-'+i}) &&
                      window.panels[i].textContent.includes('unsaved'));""")

                until(lambda: js("return !!document.querySelector('section.tile')"), "initial panels")
                request("POST", base + "/window/rect", {"width": 1600, "height": 1000})
                leaf = lambda p: {"t": "leaf", "p": p}
                split = lambda a, b, d="h": {"t": "split", "dir": d, "r": 0.4, "a": a, "b": b}
                # Configs is a tab of the Hosts panel: two Hosts tiles opened on it, beside Dispatch.
                layout = split(leaf("dispatch"), split(leaf("hosts"), leaf("hosts")))
                js("localStorage.setItem('layout', JSON.stringify(arguments[0])); localStorage.setItem('hosts.tab', 'configs')", layout)
                request("POST", base + "/refresh", {})
                until(lambda: js("return document.querySelectorAll('.tile[data-panel=hosts] .hosts-body[data-panel=configs] tbody tr').length === 2"), "real config listings")
                js("""window.nativeErrors=[];
                  const error=console.error; console.error=(...args)=>{window.nativeErrors.push(args.map(x=>String(x)+' '+(x?.stack||'')).join(' '));error(...args)};
                  window.addEventListener('error',e=>window.nativeErrors.push(e.message+' '+(e.error?.stack||'')));""")
                js("window.panels = [...document.querySelectorAll('.tile[data-panel=hosts]')]; window.panels.forEach(p => p.querySelector('tbody tr').click());")
                until(lambda: js("return document.querySelectorAll('textarea.editor').length === 2"), "real config reads")
                assert js("return [...document.querySelectorAll('textarea')].every(e => e.value === arguments[0])", original)
                js("window.editors = window.panels.map(p => p.querySelector('textarea'))")
                editors = request("POST", base + "/elements", {"using": "css selector", "value": "textarea.editor"})
                for i, editor in enumerate(editors):
                    path = base + f'/element/{editor["element-6066-11e4-a52e-4f735466cecf"]}'
                    request("POST", path + "/clear", {})
                    request("POST", path + "/value", {"text": json.dumps({"token": f"native-unsaved-secret-{i}"}, separators=(",", ":"))})
                until(intact, "independent drafts")

                # Surviving subtree moves up one level; both original DOM editors survive.
                click('[data-panel=dispatch].tile [aria-label="Close tile"]')
                until(intact, "adjacent-pane close")
                click('.tile[data-panel=hosts] [aria-label="Split right"]')
                until(intact, "split")
                # Settings is a sidebar view now; insert a panel that is not open yet.
                click('.side-item[data-panel=procurement]')
                until(intact, "sidebar insertion")
                until(lambda: js("return document.querySelectorAll('section.tile').length === 4"), "sidebar tile count")

                # Real pointer actions exercise capture, live preview, and ratio persistence.
                count = js("return document.querySelectorAll('[role=separator]').length")
                for i in range(count):
                    separator = js("""const e=document.querySelectorAll('[role=separator]')[arguments[0]];
                      const b=e.getBoundingClientRect(); return {x:b.x+b.width/2,y:b.y+b.height/2,
                        horizontal:e.getAttribute('aria-orientation')==='horizontal'};""", i)
                    before_resize = js("return localStorage.getItem('layout')")
                    x, y = round(separator["x"]), round(separator["y"])
                    dx, dy = (0, 30) if separator["horizontal"] else (30, 0)
                    request("POST", base + "/actions", {"actions": [{"type": "pointer", "id": "mouse", "parameters": {"pointerType": "mouse"}, "actions": [
                        {"type": "pointerMove", "duration": 0, "x": x, "y": y},
                        {"type": "pointerDown", "button": 0},
                        {"type": "pointerMove", "duration": 150, "x": x+dx, "y": y+dy},
                        {"type": "pointerUp", "button": 0},
                    ]}]})
                    assert intact(), "pointer resize destroyed a draft"
                    until(lambda: js("return localStorage.getItem('layout')") != before_resize, "pointer ratio commit")
                click('.tile[data-panel=hosts] [aria-label="Zoom"]')
                until(lambda: js("return !!document.querySelector('.tile.zoomed')"), "zoom")
                assert js("""const s=document.querySelector('.tile-surface').getBoundingClientRect();
                  const z=document.querySelector('.tile.zoomed').getBoundingClientRect();
                  return Math.abs(s.width-z.width)<1 && Math.abs(s.height-z.height)<1;"""), "zoom geometry"
                click('.tile[data-panel=hosts] [aria-label="Restore"]')
                assert intact()

                # Every tile has usable, non-overlapping geometry and remains in the surface.
                assert js("""const s=document.querySelector('.tile-surface').getBoundingClientRect();
                  const boxes=[...document.querySelectorAll('section.tile')].map(e=>e.getBoundingClientRect());
                  return boxes.every((a,i) => a.width>0 && a.height>0 && a.left>=s.left-1 &&
                    a.right<=s.right+1 && a.top>=s.top-1 && a.bottom<=s.bottom+1 &&
                    boxes.slice(i+1).every(b => Math.min(a.right,b.right)-Math.max(a.left,b.left)<1 ||
                      Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top)<1));"""), "tile geometry"
                assert js("""return [localStorage, sessionStorage].every(s => Object.values(s).every(v =>
                  !v.includes('native-unsaved-secret') && !v.includes('original-native-fixture')));""")
                saved = js("return localStorage.getItem('layout')")
                request("POST", base + "/refresh", {})
                until(lambda: js("return document.querySelectorAll('.tile[data-panel=hosts] .hosts-body[data-panel=configs] tbody tr').length === 2"), "restored duplicate panels")
                assert js("return document.querySelectorAll('textarea').length") == 0
                assert js("return localStorage.getItem('layout')") == saved
                assert fixture.read_text() == original, "unsaved draft changed the real fixture"
                print("PASS: native Tauri/WebKit config drafts, duplicate panels, split, adjacent close, sidebar, pointer resize, zoom, geometry, storage, restore")
                # Exercise actual reviewed writes and version guards through the real IPC backend.
                js("window.panels=[...document.querySelectorAll('.tile[data-panel=hosts]')];window.panels.forEach(p=>p.querySelector('tbody tr').click())")
                until(lambda: js("return document.querySelectorAll('textarea.editor').length===2"), "fresh config editors")
                changed = '{"token":"native-saved"}'
                js("const e=window.panels[0].querySelector('textarea');e.value=arguments[0];e.dispatchEvent(new Event('input',{bubbles:true}))", changed)
                until(lambda: js("return window.panels[0].textContent.includes('unsaved')"), "edited file")
                assert js("return [...window.panels[0].querySelectorAll('button')].find(b=>b.textContent==='Save…').disabled"), "save bypassed review"
                js("[...window.panels[0].querySelectorAll('button')].find(b=>b.textContent==='Review diff').click()")
                until(lambda: js("return window.panels[0].textContent.includes('Pending change')"), "actual reviewed diff")
                js("[...window.panels[0].querySelectorAll('button')].find(b=>b.textContent==='Save…').click()")
                until(lambda: js("return !!document.querySelector('.tile-confirm')"), "save confirmation")
                assert js("return document.querySelector('.tile-confirm pre').textContent.includes('native-saved')"), "confirmation omitted reviewed diff"
                click('.tile-confirm .btn.danger')
                until(lambda: fixture.read_text() == changed, "real guarded config write")
                until(lambda: js("return !document.querySelector('.tile-confirm')"), "save completed")
                backups = list(root.glob("app.json.bak-*"))
                assert len(backups) == 1 and backups[0].read_text() == original, "backup did not preserve opened bytes"
                js("const e=window.panels[1].querySelector('textarea');e.value=arguments[0];e.dispatchEvent(new Event('input',{bubbles:true}))", '{"token":"stale-draft"}')
                js("[...window.panels[1].querySelectorAll('button')].find(b=>b.textContent==='Review diff').click()")
                until(lambda: js("return window.panels[1].textContent.includes('File changed since it was opened')"), "duplicate stale editor refusal")
                assert fixture.read_text() == changed, "stale editor overwrote the saved file"
                assert js("return window.panels[1].querySelector('textarea').value.includes('stale-draft')"), "stale refusal discarded the draft"
                print("PASS: native reviewed save, exact backup, stale duplicate refusal and draft retention")
                click('.tile[data-panel=hosts] .hosts-tab[data-tab=scripts]')
                until(lambda: js("return !!document.querySelector('[data-panel=scripts].hosts-body .card')"), "actual script discovery")
                js("[...document.querySelector('[data-panel=scripts].hosts-body').querySelectorAll('button')].find(b=>b.textContent==='Dry run').click()")
                until(lambda: js("return document.querySelector('[data-panel=scripts].hosts-body').textContent.includes('dry-run confirmed') && document.querySelector('[data-panel=scripts].hosts-body').textContent.includes('exit 0')"), "explicit dry-run output")
                assert not applied.exists(), "dry run applied a change"
                js("[...document.querySelector('[data-panel=scripts].hosts-body').querySelectorAll('button')].find(b=>b.textContent==='Apply').click()")
                until(lambda: js("return !!document.querySelector('.tile-confirm')"), "apply confirmation")
                assert js("return document.querySelector('.tile-confirm pre').textContent.includes('--apply')")
                click('.tile-confirm .actions .btn:first-child')
                assert not applied.exists(), "cancelled apply ran the script"
                js("[...document.querySelector('[data-panel=scripts].hosts-body').querySelectorAll('button')].find(b=>b.textContent==='Apply').click()")
                until(lambda: js("return !!document.querySelector('.tile-confirm')"), "second apply confirmation")
                click('.tile-confirm .btn.danger')
                until(lambda: applied.exists(), "confirmed real apply")
                assert applied.read_text().strip() == "applied"
                print("PASS: native script discovery, explicit dry-run, cancelled apply and confirmed apply")
                def ipc(command, args):
                    return request("POST", base + "/execute/async", {
                        "script": "const done=arguments[arguments.length-1];window.__TAURI_INTERNALS__.invoke(arguments[0],arguments[1]).then(value=>done({ok:true,value}),error=>done({ok:false,reason:String(error)}));",
                        "args": [command, args],
                    })
                large = json.dumps({"large": "x" * 100_000})
                result = ipc("write_config", {"host": "local", "path": str(fixture), "expected": changed, "content": large})
                assert result["ok"], result
                assert fixture.read_text() == large, "large snapshot did not reach actual config IPC"
                print("PASS: native large snapshot transported outside argv")
                if service_owner_fixture:
                    result = ipc("write_config", {"host": "local", "path": str(service_file), "expected": service_original, "content": '{"service":"edited"}'})
                    assert not result["ok"], "service-owned config was replaced with an operator-owned file"
                    assert "Cannot preserve config owner" in result["reason"], result
                    assert service_file.stat().st_uid == 0
                    assert service_file.read_text() == service_original
                    print("PASS: native service-owned group-writable config save refused without ownership/content changes")

                if procurement:
                    origin, unexpected = procurement
                    launcher = '[data-panel=procurement].tile [data-procurement-open]'
                    save_address = '[data-panel=procurement].tile [data-procurement-save]'
                    click('.side-item[data-panel=procurement]')
                    # Use a full tile so controls remain clickable after the earlier resize tests.
                    click('.tile[data-panel=procurement] [aria-label="Zoom"]')
                    until(lambda: js("const b=document.querySelector(arguments[0]);return b && !b.disabled", save_address), "connection setup ready")
                    assert js("return document.querySelector(arguments[0]).disabled", launcher), "missing origin did not require setup"
                    js("document.querySelector('[aria-label=\"Procurement server address\"]').value=arguments[0]", origin)
                    click(save_address)
                    until(lambda: js("return !!document.querySelector('.tile-confirm .btn.go')"), "connection review")
                    assert js("return document.querySelector('.tile-confirm pre').textContent.includes(arguments[0])", origin)
                    # Cancellation must leave the existing config byte-for-byte untouched.
                    before_connection = config_path.read_bytes()
                    click('.tile-confirm .actions .btn:first-child')
                    assert config_path.read_bytes() == before_connection
                    until(lambda: js("return !document.querySelector(arguments[0]).disabled", save_address), "cancelled connection review")
                    click(save_address)
                    until(lambda: js("return !!document.querySelector('.tile-confirm .btn.go')"), "second connection review")
                    click('.tile-confirm .btn.go')
                    until(lambda: js("return !document.querySelector('.tile-confirm') && !document.querySelector(arguments[0]).disabled", launcher), "connection saved through UI")
                    saved_connection = json.loads(config_path.read_text())
                    assert saved_connection.pop("procurementOrigin") == origin + "/"
                    assert saved_connection == config_data, "connection setup changed unrelated settings"
                    # Reload the desktop and recover the persisted address, without injecting it.
                    request("POST", base + "/refresh", {})
                    until(lambda: js("const b=document.querySelector(arguments[0]);return b && !b.disabled", launcher), "persisted launcher after reload")
                    print("PASS: visible Procurement setup, cancellation, reviewed save and persisted connection", flush=True)
                    main = request("GET", base + "/window")
                    click(launcher)
                    handles = until(lambda: (rows if len(rows := request("GET", base + "/window/handles")) == 2 else None), "procurement window")
                    remote = next(handle for handle in handles if handle != main)
                    request("POST", base + "/window", {"handle": remote})
                    until(lambda: js("return location.pathname === '/requests' && document.querySelector('h1')?.textContent === 'Procurement HTTPS fixture'"), "trusted HTTPS page and redirect")
                    print("PASS: packaged Procurement launcher and trusted HTTPS redirect", flush=True)

                    # Drive ordinary navigation directly in the remote document.
                    # WebKitDriver's element lookup can disconnect in this window.
                    js("setTimeout(() => document.querySelector('#foreign').click(), 0)")
                    point = js("""const b = document.querySelector('#popup').getBoundingClientRect();
                        return {x: Math.round(b.x + b.width / 2), y: Math.round(b.y + b.height / 2)};""")
                    # Use a user gesture so browser popup suppression cannot stand
                    # in for the app's explicit new-window refusal.
                    request("POST", base + "/actions", {"actions": [{
                        "type": "pointer", "id": "procurement-popup", "parameters": {"pointerType": "mouse"},
                        "actions": [
                            {"type": "pointerMove", "duration": 0, **point},
                            {"type": "pointerDown", "button": 0},
                            {"type": "pointerUp", "button": 0},
                        ],
                    }]})
                    js("setTimeout(() => document.querySelector('#orders').click(), 0)")
                    until(lambda: js("return location.pathname === '/orders'"), "same-origin procurement navigation")
                    assert not unexpected, f"procurement escaped its window or origin: {unexpected}"
                    assert set(request("GET", base + "/window/handles")) == {main, remote}
                    print("PASS: packaged Procurement same-origin navigation and popup blocking", flush=True)

                    for command, args in [
                        ("app_info", {}),
                        ("procurement_status", {}),
                        ("save_procurement_origin", {"origin": origin, "expectedRevision": "not-authorized"}),
                        ("read_config", {"host": "local", "path": str(fixture)}),
                        ("run_on", {"host": "local", "script": "printf unexpected"}),
                    ]:
                        denied = request("POST", base + "/execute/async", {
                            "script": """
                                const done = arguments[arguments.length - 1];
                                const bridge = window.__TAURI_INTERNALS__;
                                if (!bridge?.invoke) { done(true); return; }
                                bridge.invoke(arguments[0], arguments[1]).then(() => done(false), () => done(true));
                            """,
                            "args": [command, args],
                        })
                        assert denied is True, f"procurement webview invoked {command}"
                    print("PASS: packaged Procurement webview desktop IPC denial", flush=True)

            except Exception:
                try:
                    print("Native geometry:", request("POST", base + "/execute/sync", {
                        "script": "return [...document.querySelectorAll('.tiles,.tile-surface,.tile,textarea')].map(e => ({tag:e.tagName,cls:e.className,rect:e.getBoundingClientRect().toJSON()}))", "args": []}))
                    print("Native page:", request("POST", base + "/execute/sync", {
                        "script": "return {url:location.href,ready:document.readyState,text:document.body.innerText.slice(0,1000)}", "args": []}))
                    print("Native errors:", request("POST", base + "/execute/sync", {
                        "script": "return window.nativeErrors", "args": []}))
                except Exception:
                    pass
                log.flush()
                log.seek(0)
                print(log.read())
                raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=lambda s: Path(s).resolve())
    parser.add_argument("--session-timeout", type=float, default=60,
                        help="Bound the native WebDriver handshake (seconds; default: 60).")
    parser.add_argument("--service-owner-fixture", action="store_true",
                        help="Also require the Linux CI service-owned file regression (uses sudo only to create the disposable fixture).")
    parser.add_argument("--procurement-tls", nargs=2, metavar=("CERTIFICATE", "KEY"),
                        help="Also check the Procurement webview using a disposable HTTPS certificate trusted by this test system.")
    args = parser.parse_args()
    run(args.binary, args.session_timeout, args.service_owner_fixture, args.procurement_tls)