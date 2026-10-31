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


def run(binary, session_timeout=60):
    with tempfile.TemporaryDirectory(prefix="biz-kit-panels-") as tmp:
        root = Path(tmp)
        fixture = root / "app.json"
        original = '{"token":"original-native-fixture"}'
        fixture.write_text(original)
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
    args = parser.parse_args()
    run(args.binary, args.session_timeout)
