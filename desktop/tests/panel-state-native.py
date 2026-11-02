#!/usr/bin/env python3
"""Linux Tauri acceptance: real WebKit, IPC, file reads, and unsaved editors.

Build: npm run tauri build -- --debug --no-bundle
Run:   xvfb-run -a -s '-screen 0 1920x1080x24' python3 tests/panel-state-native.py src-tauri/target/debug/biz-kit
Needs tauri-driver 2.0.4 and WebKitWebDriver on PATH. Uses disposable XDG dirs
and a synthetic config; never touches an operator's files or credentials.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def until(check, description):
    end = time.monotonic() + 20
    while time.monotonic() < end:
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError(f"Timed out: {description}")


def run(binary, session_timeout=60, service_owner_fixture=False):
    with tempfile.TemporaryDirectory(prefix="biz-kit-panels-") as tmp:
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
        (config / "config.json").write_text(json.dumps({
            "hosts": [{"name": "local", "label": "Local fixture", "ssh": None}],
            "configs": [{"path": str(fixture), "label": "Native fixture"}],
            "scriptsDir": str(root / "scripts"),
        }))
        env = {**os.environ, "XDG_CONFIG_HOME": str(root / "config"),
               "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache")}
        port, native_port = free_port(), free_port()
        # Ignore shell proxy variables for the local WebDriver connection.
        http = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def request(method, path, payload=None, timeout=30):
            data = None if payload is None else json.dumps(payload).encode()
            req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                         headers={"Content-Type": "application/json"}, method=method)
            try:
                with http.open(req, timeout=timeout) as reply:
                    result = json.load(reply)
            except urllib.error.HTTPError as error:
                raise AssertionError(error.read().decode()) from error
            value = result.get("value")
            if isinstance(value, dict) and "error" in value:
                raise AssertionError(value)
            return value

        with open(root / "driver.log", "w+") as log:
            driver = subprocess.Popen(["tauri-driver", "--port", str(port), "--native-port", str(native_port)],
                                      env=env, stdout=log, stderr=log, start_new_session=True)
            session = None
            try:
                def ready():
                    if driver.poll() is not None:
                        log.seek(0)
                        raise AssertionError(log.read())
                    try:
                        for endpoint in (port, native_port):
                            with socket.create_connection(("127.0.0.1", endpoint), timeout=0.1):
                                pass
                        return True
                    except OSError:
                        return False
                until(ready, "tauri-driver")
                print("Native acceptance: creating Tauri/WebKit session", flush=True)
                session = request("POST", "/session", {"capabilities": {"alwaysMatch": {
                    "tauri:options": {"application": str(binary)},
                }}}, timeout=session_timeout)["sessionId"]
                base = f"/session/{session}"
                print("Native acceptance: session ready; exercising mounted editors", flush=True)

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
                layout = split(leaf("services"), split(leaf("configs"), leaf("configs")))
                js("localStorage.setItem('layout', JSON.stringify(arguments[0]))", layout)
                request("POST", base + "/refresh", {})
                until(lambda: js("return document.querySelectorAll('[data-panel=configs].tile tbody tr').length === 2"), "real config listings")
                js("""window.nativeErrors=[];
                  const error=console.error; console.error=(...args)=>{window.nativeErrors.push(args.map(x=>String(x)+' '+(x?.stack||'')).join(' '));error(...args)};
                  window.addEventListener('error',e=>window.nativeErrors.push(e.message+' '+(e.error?.stack||'')));""")
                js("window.panels = [...document.querySelectorAll('[data-panel=configs].tile')]; window.panels.forEach(p => p.querySelector('tbody tr').click());")
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
                click('[data-panel=services].tile [aria-label="Close tile"]')
                until(intact, "adjacent-pane close")
                click('[data-panel=configs].tile [aria-label="Split right"]')
                until(intact, "split")
                click('.entry[data-panel=settings]')
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
                click('[data-panel=configs].tile [aria-label="Zoom"]')
                until(lambda: js("return !!document.querySelector('.tile.zoomed')"), "zoom")
                assert js("""const s=document.querySelector('.tile-surface').getBoundingClientRect();
                  const z=document.querySelector('.tile.zoomed').getBoundingClientRect();
                  return Math.abs(s.width-z.width)<1 && Math.abs(s.height-z.height)<1;"""), "zoom geometry"
                click('[data-panel=configs].tile [aria-label="Restore"]')
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
                until(lambda: js("return document.querySelectorAll('[data-panel=configs].tile tbody tr').length === 2"), "restored duplicate panels")
                assert js("return document.querySelectorAll('textarea').length") == 0
                assert js("return localStorage.getItem('layout')") == saved
                assert fixture.read_text() == original, "unsaved draft changed the real fixture"
                print("PASS: native Tauri/WebKit config drafts, duplicate panels, split, adjacent close, sidebar, pointer resize, zoom, geometry, storage, restore")
                # Exercise actual reviewed writes and version guards through the real IPC backend.
                js("window.panels=[...document.querySelectorAll('[data-panel=configs].tile')];window.panels.forEach(p=>p.querySelector('tbody tr').click())")
                until(lambda: js("return document.querySelectorAll('textarea.editor').length===2"), "fresh config editors")
                changed = '{"token":"native-saved"}'
                js("const e=window.panels[0].querySelector('textarea');e.value=arguments[0];e.dispatchEvent(new Event('input',{bubbles:true}))", changed)
                until(lambda: js("return window.panels[0].textContent.includes('unsaved')"), "edited file")
                assert js("return [...window.panels[0].querySelectorAll('button')].find(b=>b.textContent==='Save…').disabled"), "save bypassed review"
                js("[...window.panels[0].querySelectorAll('button')].find(b=>b.textContent==='Review diff').click()")
                until(lambda: js("return window.panels[0].textContent.includes('Pending change')"), "actual reviewed diff")
                js("[...window.panels[0].querySelectorAll('button')].find(b=>b.textContent==='Save…').click()")
                until(lambda: js("return !!document.querySelector('.modal')"), "save confirmation")
                assert js("return document.querySelector('.modal pre').textContent.includes('native-saved')"), "confirmation omitted reviewed diff"
                click('.modal .btn.danger')
                until(lambda: fixture.read_text() == changed, "real guarded config write")
                until(lambda: js("return !document.querySelector('.modal')"), "save completed")
                backups = list(root.glob("app.json.bak-*"))
                assert len(backups) == 1 and backups[0].read_text() == original, "backup did not preserve opened bytes"
                js("const e=window.panels[1].querySelector('textarea');e.value=arguments[0];e.dispatchEvent(new Event('input',{bubbles:true}))", '{"token":"stale-draft"}')
                js("[...window.panels[1].querySelectorAll('button')].find(b=>b.textContent==='Review diff').click()")
                until(lambda: js("return window.panels[1].textContent.includes('File changed since it was opened')"), "duplicate stale editor refusal")
                assert fixture.read_text() == changed, "stale editor overwrote the saved file"
                assert js("return window.panels[1].querySelector('textarea').value.includes('stale-draft')"), "stale refusal discarded the draft"
                print("PASS: native reviewed save, exact backup, stale duplicate refusal and draft retention")
                click('button[data-panel=scripts]')
                until(lambda: js("return !!document.querySelector('[data-panel=scripts].tile .card')"), "actual script discovery")
                js("[...document.querySelector('[data-panel=scripts].tile').querySelectorAll('button')].find(b=>b.textContent==='Dry run').click()")
                until(lambda: js("return document.querySelector('[data-panel=scripts].tile').textContent.includes('dry-run confirmed') && document.querySelector('[data-panel=scripts].tile').textContent.includes('exit 0')"), "explicit dry-run output")
                assert not applied.exists(), "dry run applied a change"
                js("[...document.querySelector('[data-panel=scripts].tile').querySelectorAll('button')].find(b=>b.textContent==='Apply').click()")
                until(lambda: js("return !!document.querySelector('.modal')"), "apply confirmation")
                assert js("return document.querySelector('.modal pre').textContent.includes('--apply')")
                click('.modal .btn:not(.danger)')
                assert not applied.exists(), "cancelled apply ran the script"
                js("[...document.querySelector('[data-panel=scripts].tile').querySelectorAll('button')].find(b=>b.textContent==='Apply').click()")
                until(lambda: js("return !!document.querySelector('.modal')"), "second apply confirmation")
                click('.modal .btn.danger')
                until(lambda: applied.exists(), "confirmed real apply")
                assert applied.read_text().strip() == "applied"
                print("PASS: native script discovery, explicit dry-run, cancelled apply and confirmed apply")
                def ipc(command, args):
                    return request("POST", base + "/execute/async", {
                        "script": "const done=arguments[arguments.length-1];window.__TAURI_INTERNALS__.invoke(arguments[0],arguments[1]).then(value=>done({ok:true,value}),error=>done({ok:false,error:String(error)}));",
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
                    assert service_file.stat().st_uid == 0
                    assert service_file.read_text() == service_original
                    print("PASS: native service-owned group-writable config save refused without ownership/content changes")



            except Exception:
                if session:
                    try:
                        print("Native geometry:", request("POST", f"/session/{session}/execute/sync", {
                            "script": "return [...document.querySelectorAll('.main,.tile-surface,.tile,textarea')].map(e => ({tag:e.tagName,cls:e.className,rect:e.getBoundingClientRect().toJSON()}))", "args": []}))
                        print("Native page:", request("POST", f"/session/{session}/execute/sync", {
                            "script": "return {url:location.href,ready:document.readyState,text:document.body.innerText.slice(0,1000)}", "args": []}))
                        print("Native errors:", request("POST", f"/session/{session}/execute/sync", {
                            "script": "return window.nativeErrors", "args": []}))
                    except Exception:
                        pass
                log.flush()
                log.seek(0)
                print(log.read())
                raise
            finally:
                try:
                    if session:
                        request("DELETE", f"/session/{session}")
                finally:
                    # Also stop WebKit/app descendants after a failed session handshake.
                    try:
                        os.killpg(driver.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    try:
                        driver.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(driver.pid, signal.SIGKILL)
                        driver.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=lambda s: Path(s).resolve())
    parser.add_argument("--session-timeout", type=float, default=60,
                        help="Bound the native WebDriver handshake (seconds; default: 60).")
    parser.add_argument("--service-owner-fixture", action="store_true",
                        help="Also require the Linux CI service-owned file regression (uses sudo only to create the disposable fixture).")
    args = parser.parse_args()
    run(args.binary, args.session_timeout, args.service_owner_fixture)
