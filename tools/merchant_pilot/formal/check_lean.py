"""Kernel-check model, actual-exporter conformance cases and axiom dependencies."""
import argparse
from copy import deepcopy
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from intake_export import export_intake
from scorecard import score, timestamp

HERE = Path(__file__).resolve().parent
BASE = json.loads((HERE.parent / 'intake.synthetic.json').read_text())


def integer(value):
    return f'({value})'


def option(value):
    return 'none' if value is None else f'(some {integer(value)})'


def cases():
    checks = ['import MerchantPilot', 'open MerchantPilot']
    count = 0
    for refund, expense, complete, closed in itertools.product((0, 1000, 10000), (0, 7000), (False, True), (False, True)):
        b = deepcopy(BASE)
        b['orders'] = b['orders'][:1]
        order = b['orders'][0]['data']
        order['refunds'] = [dict(order['refunds'][0], minor=refund)] if refund else []
        order['reconciled_at'] = order['reconciled_at'] if closed else None
        for role, gross, partial in (('servicing_store', 250, 50), ('platform', 600, 100)):
            order['fees'][role]['reversed_minor'] = gross if refund == 10000 else partial if refund == 1000 else 0
        b['costs'][0]['data']['items'][0]['minor'] = expense
        b['costs'][0]['data']['complete'] = complete
        snapshot, _ = export_intake(b)
        result = score(snapshot, include_orders=True)
        net_store = 250 - order['fees']['servicing_store']['reversed_minor']
        net_platform = 600 - order['fees']['platform']['reversed_minor']
        model = dict(merchant=(10000-refund-net_store-net_platform, expense if complete else None, 25),
                     servicing_store=(net_store, 180, 10), platform=(net_platform, 200, 100))
        for role, (revenue, cost, overhead) in model.items():
            actual = result['economics']['orders'][0]['roles'][role].get('margin_minor')
            expr = f'reportedMargin {str(closed).lower()} {option(revenue)} {option(cost)}'
            checks.append(f'example : {expr} = {option(actual)} := by decide')
            cohort = result['economics']['by_currency']['USD'][role]['scenarios'][0]['cohort_margin_minor']
            checks.append(f'example : cohortMargin true [({expr})] {option(overhead)} = {option(cohort)} := by decide')
            count += 2
    snapshot, _ = export_intake(BASE)
    result = score(snapshot)
    origin = timestamp(snapshot['cohort_started_at'])
    now = int((timestamp(snapshot['as_of']) - origin).total_seconds())
    buckets = []
    for request in snapshot['requests']:
        q = int((timestamp(request['qualified_at']) - origin).total_seconds())
        end = None if request['withdrawn_at'] is None else int((timestamp(request['withdrawn_at']) - origin).total_seconds())
        buckets.append(f'(bucket {q} {now} {option(end)} 604800)')
    for label, metric in (('mature', 'denominator'), ('incomplete', 'incomplete'), ('earlyWithdrawal', 'withdrawn_early')):
        expected = result['demand']['seven_day_match'][metric]
        checks.append(f'example : ([{", ".join(buckets)}].filter (fun b => b == Bucket.{label})).length = {expected} := by decide')
        count += 1
    return '\n'.join(checks) + '\n', count


def run(command, work, env, success=True, marker=None):
    result = subprocess.run(command, cwd=work, env=env, capture_output=True, text=True)
    output = result.stdout + result.stderr
    if success and result.returncode != 0:
        raise RuntimeError(output)
    if not success and (result.returncode == 0 or (marker and marker not in output)):
        raise RuntimeError('negative Lean control did not fail for the expected reason: ' + output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lean', default='lean')
    parser.add_argument('--leanchecker', default='leanchecker')
    parser.add_argument('--emit', type=Path, help='only emit runtime-derived synthetic examples')
    args = parser.parse_args()
    examples, count = cases()
    if args.emit:
        args.emit.write_text(examples)
        print(json.dumps(dict(runtime_examples=count, emitted=str(args.emit))))
        return
    source = (HERE / 'MerchantPilot.lean').read_text()
    # The declarations below are all kernel proofs; audit their transitive axioms too.
    names = re.findall(r'^theorem\s+(\w+)', source, flags=re.M)
    with tempfile.TemporaryDirectory(prefix='merchant-lean-') as directory:
        work = Path(directory)
        shutil.copy(HERE / 'MerchantPilot.lean', work)
        lean_path = Path(shutil.which(args.lean) or args.lean).resolve()
        env = dict(os.environ, LEAN_PATH=str(work),
                   PATH=str(lean_path.parent) + os.pathsep + os.environ.get('PATH', ''))
        version = run([args.lean, '--version'], work, env).strip()
        if 'version 4.35.0' not in version:
            raise RuntimeError('use the repository-pinned Lean 4.35.0 toolchain')
        run([args.lean, '-o', 'MerchantPilot.olean', 'MerchantPilot.lean'], work, env)
        run([args.leanchecker, '--fresh', 'MerchantPilot'], work, env)
        (work / 'RuntimeChecks.lean').write_text(examples)
        run([args.lean, 'RuntimeChecks.lean'], work, env)
        (work / 'Audit.lean').write_text('import MerchantPilot\n' + '\n'.join(
            '#print axioms MerchantPilot.' + name for name in names))
        audit = run([args.lean, 'Audit.lean'], work, env)
        allowed = {'propext', 'Classical.choice', 'Quot.sound'}
        for group in re.findall(r'depends on axioms:\s*\[([^]]*)\]', audit):
            actual = {name.strip() for name in group.split(',') if name.strip()}
            if not actual <= allowed:
                raise RuntimeError('unapproved transitive axiom: ' + repr(actual - allowed))
        if 'sorryAx' in audit:
            raise RuntimeError('admitted proof in axiom audit')
        (work / 'WrongRefund.lean').write_text('import MerchantPilot\nopen MerchantPilot\n'
            'example : (margins 10000 10000 0 0 7000 180 200).merchant = 0 := by decide\n')
        run([args.lean, 'WrongRefund.lean'], work, env, success=False, marker='decide')
        (work / 'MixedCurrency.lean').write_text('import MerchantPilot\nopen MerchantPilot\n'
            'def invalid := addAmount (⟨1⟩ : Amount .USD) (⟨1⟩ : Amount .JPY)\n')
        run([args.lean, 'MixedCurrency.lean'], work, env, success=False, marker='type mismatch')
        print(json.dumps(dict(toolchain=version, named_proofs=len(names), runtime_examples=count,
                              negative_controls=2, permitted_axioms=sorted(allowed), dataset='synthetic')))


if __name__ == '__main__':
    main()
