"""Drive the installed Linux desktop payload through its real HTTPS forms."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
from queue import Empty
import subprocess
import sys
import time

from release_acceptance import Browser, digest, require

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "desktop/tests"))
from native_webdriver import native_session, until


class NativeBrowser(Browser):
    def __init__(self, origin, observations, webdriver, base, identity):
        self.url, self.observations = origin, observations
        self.webdriver, self.base, self.identity = webdriver, base, identity

    def js(self, script, *args):
        return self.webdriver("POST", self.base + "/execute/sync", {"script": script, "args": list(args)})

    def open_procurement(self):
        main = self.webdriver("GET", self.base + "/window")
        panel = '.entry[data-panel=procurement]'
        until(lambda: self.js("return !!document.querySelector(arguments[0])", panel), "desktop Procurement entry")
        self.js("document.querySelector(arguments[0]).click()", panel)
        launcher = '[data-panel=procurement].tile button:not(.icon-btn)'
        until(lambda: self.js("return !!document.querySelector(arguments[0])", launcher), "Procurement launcher")
        self.js("document.querySelector(arguments[0]).click()", launcher)
        handles = until(lambda: set(self.webdriver("GET", self.base + "/window/handles")) - {main},
                        "Procurement webview")
        require(len(handles) == 1, "unexpected number of Procurement windows")
        self.webdriver("POST", self.base + "/window", {"handle": handles.pop()})
        until(lambda: self.js("return location.origin === arguments[0] && location.pathname === '/login' && !!document.querySelector('form[action=\"/login\"]')", self.url),
              "actual procurement login through trusted HTTPS")

    def has_secure_session(self):
        cookies = self.webdriver("GET", self.base + "/cookie")
        return any(cookie["name"] == "_procurement_pilot" and cookie.get("secure") and cookie.get("httpOnly")
                   for cookie in cookies)

    def request(self, path, fields=None):
        return self.navigate(path, fields, rendered=False)

    def submit(self, form, fields, expected=303):
        values = dict(form["fields"], **fields)
        # A stale quote and an exact retry deliberately replay a prior payload.
        status, body, headers = self.navigate(form["action"], values, rendered=bool(form["fields"]) and expected != 409)
        require(status == expected, f"native form {form['action']} returned {status}, expected {expected}")
        return values, body, headers

    def navigate(self, path, fields, *, rendered):
        require(path.startswith("/") and not path.startswith("//"), "non-local native form action")
        while not self.observations.empty():
            self.observations.get_nowait()
        previous = self.js("""
            const [origin, path, fields, rendered] = arguments;
            const target = new URL(path, origin);
            if (location.origin !== origin || target.origin !== origin) return 'unexpected origin';
            if (fields === null) {
              setTimeout(() => location.href === target.href ? location.reload() : location.assign(target), 0);
            } else if (rendered) {
              const forms = [...document.forms].filter(f => f.action === target.href);
              if (forms.length !== 1) return 'missing or ambiguous form';
              const form = forms[0];
              for (const [name, value] of Object.entries(fields)) {
                const field = form.elements.namedItem(name);
                if (!field) return 'missing field ' + name;
                if (field.type === 'hidden') {
                  if (field.value !== value) return 'changed hidden field ' + name;
                } else {
                  field.value = value;
                  if (field.value !== value) return 'field rejected value: ' + name;
                }
              }
              if (!form.checkValidity()) return 'form validation failed';
              setTimeout(() => form.requestSubmit(), 0);
            } else {
              const form = document.createElement('form');
              form.action = target.href;
              form.method = 'POST';
              for (const [name, value] of Object.entries(fields)) {
                const field = document.createElement('input');
                Object.assign(field, {type: 'hidden', name, value});
                form.append(field);
              }
              document.body.append(form);
              setTimeout(() => form.requestSubmit(), 0);
            }
            return performance.timeOrigin;
        """, self.url, path, fields, rendered)
        require(isinstance(previous, (int, float)), f"cannot drive native form or page {path}: {previous}")

        method = "GET" if fields is None else "POST"
        deadline = time.monotonic() + 20
        try:
            while True:
                actual, route, status, headers = self.observations.get(timeout=max(0, deadline - time.monotonic()))
                if (actual, route) == (method, path):
                    break
                if time.monotonic() >= deadline:
                    raise Empty
        except Empty:
            raise RuntimeError(f"no HTTPS proxy response for native {method} {path}") from None

        landed = headers["Location"] if status == 303 else path
        body = until(lambda: self.js("""
            if (location.origin !== arguments[0] || location.pathname !== arguments[1]
                || performance.timeOrigin === arguments[2] || document.readyState !== 'complete') return null;
            return document.documentElement.outerHTML;
        """, self.url, landed, previous), f"native document after {method} {path}")
        return status, body, headers


@contextmanager
def packaged_browser(package, origin, observations, work, receipts):
    package = package.resolve()
    require(package.is_file() and package.suffix == ".deb", "a Linux desktop .deb is required")
    root = work / "desktop-package"
    subprocess.run(["dpkg-deb", "--extract", package, root], check=True, timeout=60)
    binary = root / "usr/bin/biz-kit"
    require(binary.is_file() and os.access(binary, os.X_OK), "no packaged Biz-kit executable")
    identity = {"package_sha256": digest(package), "executable_sha256": digest(binary)}
    allowed = {"PATH", "LANG", "DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR",
               "LIBGL_ALWAYS_SOFTWARE", "WEBKIT_DISABLE_DMABUF_RENDERER", "WEBKIT_DISABLE_COMPOSITING_MODE",
               "NO_AT_BRIDGE", "LD_LIBRARY_PATH"}
    env = {key: value for key, value in os.environ.items() if key in allowed}
    home = work / "desktop-home"
    config = home / "config/biz-kit"
    config.mkdir(parents=True)
    (config / "config.json").write_text(json.dumps({"procurementOrigin": origin}) + "\n")
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / "config"),
               XDG_DATA_HOME=str(home / "data"), XDG_CACHE_HOME=str(home / "cache"))
    with (receipts / "tauri-driver.log").open("w") as log, native_session(binary, env, log) as (request, base):
        browser = NativeBrowser(origin, observations, request, base, identity)
        browser.open_procurement()
        yield browser
