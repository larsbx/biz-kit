"""Reproduce the inherited tuple mismatch; restore source before normal acceptance."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'apps/dispatch/lib/dispatch_web/controllers/mobile_session_controller.ex'
original = SOURCE.read_text()
needle = '{:ok, token} <-'
if original.count(needle) != 1:
    sys.exit('Expected one native exchange result match')
try:
    SOURCE.write_text(original.replace(needle, '{:ok, token, _expires_in} <-'))
    result = subprocess.run(
        ['mix', 'test', 'test/dispatch_web/mobile_session_test.exs'],
        cwd=ROOT / 'apps/dispatch', capture_output=True, text=True, timeout=120,
    )
    output = result.stdout + result.stderr
    # A build/setup failure does not establish the original HTTP regression.
    if not (result.returncode == 2 and 'exchanged.status == 200' in output
            and '401' in output):
        sys.exit('Original session mismatch did not reproduce the expected HTTP 401 assertion:\n' + output)
finally:
    SOURCE.write_text(original)
print('PASS: inherited three-element result match reproduced HTTP 401; source restored')
