"""Synthetic replay and adversarial controls. These tests are not pilot evidence."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

from intake_export import assemble, canonical, export_intake
from scorecard import InvalidSnapshot, score

HERE = Path(__file__).resolve().parent


class IntakeExportTest(unittest.TestCase):
    def setUp(self):
        self.bundle = json.loads((HERE / 'intake.synthetic.json').read_text())

    def result(self):
        snapshot, manifest = export_intake(self.bundle)
        return snapshot, manifest, score(snapshot, include_orders=True)

    def test_independent_denominators_and_role_margins(self):
        snapshot, manifest, result = self.result()
        self.assertEqual(len(manifest['excluded_requests']), 1)
        self.assertEqual(result['dataset'], 'synthetic')
        self.assertEqual(result['demand']['qualified_requests'], 4)
        self.assertEqual(result['demand']['seven_day_match'],
                         dict(numerator=1, denominator=2, incomplete=1, withdrawn_early=1))
        self.assertEqual(result['demand']['seven_day_invitation_response'], dict(numerator=1, denominator=2))
        self.assertEqual(result['demand']['first_quote_within_seven_days']['median_seconds'], 86400)
        self.assertEqual(result['orders']['on_time_fulfillment'],
                         dict(numerator=1, denominator=1, incomplete=1, pending_past_promise=1))
        self.assertEqual(result['orders']['intervention_disputes_30_day'],
                         dict(numerator=1, denominator=1, incomplete=1))
        self.assertEqual(result['orders']['merchant_repeat_90_day'],
                         dict(numerator=0, denominator=1, incomplete=0))
        roles = result['economics']['orders'][0]['roles']
        # Actual confirmed revenue 10,000 - refund 1,000 - store net 200 - platform net 500.
        self.assertEqual(roles['merchant']['revenue_minor'], 8300)
        self.assertEqual({role: d['margin_minor'] for role, d in roles.items()},
                         dict(merchant=1300, servicing_store=20, platform=300))
        byrole = result['economics']['by_currency']['USD']
        self.assertEqual(byrole['servicing_store']['scenarios'][0]['cohort_margin_minor'], 10)
        self.assertIsNone(byrole['merchant']['scenarios'][0]['cohort_margin_minor'])
        self.assertIsNone(byrole['platform']['scenarios'][0]['cohort_margin_minor'])
        self.assertEqual(manifest['snapshot_sha256'], hashlib.sha256(canonical(snapshot)).hexdigest())

    def test_separate_source_extract_assembly_is_lossless(self):
        collections = ('merchants', 'requests', 'invitations', 'quotes', 'fee_arrangements', 'orders', 'costs')
        control = {k: deepcopy(v) for k, v in self.bundle.items() if k not in collections}
        prepared = [dict(collection=c, record=deepcopy(r)) for c in collections for r in self.bundle[c]]
        self.assertEqual(assemble(control, prepared), self.bundle)
        self.assertEqual(export_intake(assemble(control, prepared)), export_intake(self.bundle))

    def test_source_and_quote_revisions_preserved_and_superseded(self):
        snapshot, manifest, _ = self.result()
        q = sorted(snapshot['quotes'], key=lambda x: x['issued_at'])
        self.assertEqual(q[0]['withdrawn_at'], q[1]['issued_at'])
        self.assertNotEqual(q[0]['id'], q[1]['id'])
        self.assertEqual(snapshot['orders'][0]['quote_id'], q[1]['id'])
        self.assertEqual(len(manifest['quote_ids']), 3)
        self.assertEqual(len(manifest['records']), sum(len(self.bundle[c]) for c in
                         ('merchants', 'requests', 'invitations', 'quotes', 'orders', 'fee_arrangements', 'costs')))
        self.bundle['orders'][0]['data']['quote_ref']['revision'] = 1
        with self.assertRaisesRegex(InvalidSnapshot, 'inactive quote'):
            self.result()

    def test_missing_pool_unknown_item_and_incomplete_inventory_remain_unknown(self):
        for mode in ('missing', 'unknown', 'partial'):
            with self.subTest(mode=mode):
                b = deepcopy(self.bundle)
                pool = b['costs'][0]
                if mode == 'missing':
                    b['costs'].remove(pool)
                elif mode == 'unknown':
                    pool['data']['items'][0]['minor'] = None
                else:
                    pool['data']['complete'] = False
                snapshot, _ = export_intake(b)
                self.assertIsNone(snapshot['orders'][0]['costs_minor']['merchant'])
                roles = score(snapshot, include_orders=True)['economics']['orders'][0]['roles']
                self.assertEqual(roles['merchant']['status'], 'missing_inputs')
                self.assertEqual(roles['platform']['margin_minor'], 300)

    def test_unallocated_absence_is_not_zero_and_explicit_zero_is_zero(self):
        self.bundle['costs'] = [r for r in self.bundle['costs'] if r['data']['order_id'] is not None]
        snapshot, _, result = self.result()
        self.assertTrue(all(r['minor'] is None for r in snapshot['unallocated_costs']))
        self.assertIsNone(result['economics']['by_currency']['USD']['servicing_store']['scenarios'][0]['cohort_margin_minor'])
        pool = deepcopy(self.bundle['costs'][0])
        pool['record_id'] = 'f' * 32
        pool['data'].update(order_id=None, role='servicing_store', complete=True, items=[])
        self.bundle['costs'].append(pool)
        _, _, result = self.result()
        self.assertEqual(result['economics']['by_currency']['USD']['servicing_store']['scenarios'][0]['cohort_margin_minor'], 20)

    def test_absent_store_cannot_hide_an_explicit_unknown_expense(self):
        pool = deepcopy(self.bundle['costs'][1])
        pool['record_id'] = 'f' * 32
        pool['data'].update(order_id=self.bundle['orders'][1]['data']['id'], complete=False, items=[])
        self.bundle['costs'].append(pool)
        with self.assertRaisesRegex(InvalidSnapshot, 'absent store'):
            self.result()

    def test_full_refund_fee_reversals_leave_actual_costs(self):
        order = self.bundle['orders'][0]['data']
        order['refunds'][0]['minor'] = 10000
        for fee in order['fees'].values():
            fee['reversed_minor'] = fee['gross_minor']
        _, _, result = self.result()
        self.assertEqual({role: r['margin_minor'] for role, r in result['economics']['orders'][0]['roles'].items()},
                         dict(merchant=-7000, servicing_store=-180, platform=-200))
        self.assertEqual(result['orders']['realized_orders'], 1)

    def test_cancelled_order_still_bears_costs(self):
        order = self.bundle['orders'][0]['data']
        order.update(outcome='cancelled', paid_at=None, gross_minor=0, refunds=[],
                     returned_at=None, disputed_at=None)
        for fee in order['fees'].values():
            fee.update(gross_minor=0, reversed_minor=0)
        _, _, result = self.result()
        self.assertEqual(result['orders']['cancelled'], dict(numerator=1, denominator=1))
        self.assertEqual(result['economics']['orders'][0]['roles']['merchant']['margin_minor'], -7000)

    def test_sharing_revocation_preserves_historical_qualification(self):
        request = self.bundle['requests'][2]['data']
        request['withdrawn_at'] = None
        request['consent']['sharing_revoked_at'] = '2026-01-03T00:00:00Z'
        snapshot, manifest, result = self.result()
        self.assertEqual(result['demand']['seven_day_match']['withdrawn_early'], 1)
        self.assertEqual(len(snapshot['requests']), 4)
        self.assertTrue(any(r['data'].get('consent') == request['consent'] for r in manifest['records']))
        request['consent']['measurement_authorized'] = False
        with self.assertRaisesRegex(InvalidSnapshot, 'retention'):
            self.result()

    def test_stale_source_and_lost_individual_followup_refuse_export(self):
        for stream, field in (('coverage', 'through'), ('requests', 'observed_through'), ('orders', 'observed_through')):
            with self.subTest(stream=stream):
                b = deepcopy(self.bundle)
                row = b[stream][0] if stream == 'coverage' else b[stream][0]['data']
                row[field] = '2026-04-09T00:00:00Z'
                with self.assertRaisesRegex(InvalidSnapshot, 'cutoff'):
                    export_intake(b)

    def test_recent_merchant_repeat_cohort_stays_incomplete(self):
        self.bundle['as_of'] = '2026-02-21T00:00:00Z'
        for c in ('requests', 'invitations', 'quotes', 'orders'):
            self.bundle[c] = [r for r in self.bundle[c] if
                             r['data'].get('id') not in ('00000000000000000000000000000130', '000000000000000000000000000004b2')
                             and r['data'].get('request_id') != '00000000000000000000000000000130']
        for c in ('merchants', 'requests', 'invitations', 'quotes', 'orders', 'fee_arrangements', 'costs'):
            for row in self.bundle[c]:
                row['captured_at'] = self.bundle['as_of']
        _, _, result = self.result()
        self.assertEqual(result['orders']['merchant_repeat_90_day'], dict(numerator=0, denominator=0, incomplete=1))

    def test_fail_closed_controls(self):
        changes = [
            ('merchant branch inflation', lambda b: b['merchants'][1]['data'].update(business_id=b['merchants'][0]['data']['business_id'])),
            ('duplicate envelope', lambda b: b['requests'].append(deepcopy(b['requests'][0]))),
            ('duplicate invitation', lambda b: b['invitations'].append(dict(deepcopy(b['invitations'][0]), record_id='f'*32))),
            ('revision gap', lambda b: b['quotes'][1].update(revision=3)),
            ('merchant ownership', lambda b: b['quotes'][0].update(owner_id='f'*32)),
            ('stock revalidation', lambda b: b['orders'][0]['data'].update(stock_terms_revalidated=False)),
            ('provider claim', lambda b: b['orders'][0]['data'].update(provider_verified=False)),
            ('refund claim', lambda b: b['orders'][0]['data']['refunds'][0].update(provider_verified=False)),
            ('excess refund', lambda b: b['orders'][0]['data']['refunds'][0].update(minor=10001)),
            ('withdrawn quote', lambda b: b['quotes'][1]['data'].update(withdrawn_at='2026-01-04T00:00:00Z')),
            ('expired quote', lambda b: b['quotes'][1]['data'].update(expires_at='2026-01-04T00:00:00Z')),
            ('no consent', lambda b: b['requests'][0]['data']['consent'].update(granted_at=None)),
            ('out of scope', lambda b: b['requests'][0]['data'].update(geography='f'*32)),
            ('participant withdrawn', lambda b: b['merchants'][0]['data'].update(withdrawn_at='2026-01-02T00:00:00Z')),
            ('observed without approval', lambda b: b.update(dataset='observed')),
            ('extra personal field', lambda b: b['requests'][0]['data'].update(email='private-token')),
            ('currency mismatch', lambda b: b['costs'][0]['data'].update(currency='JPY')),
            ('duplicate expense', lambda b: b['costs'][1]['data']['items'][0].update(id=b['costs'][0]['data']['items'][0]['id'])),
            ('buyer-direct fee', lambda b: b['quotes'][0]['data'].update(buyer_fee_minor=100)),
            ('nonmerchant fee payer', lambda b: b['fee_arrangements'][0]['data'].update(payer='buyer')),
            ('different fee supplier', lambda b: b['fee_arrangements'][0]['data'].update(merchant_id=b['merchants'][1]['data']['id'])),
        ]
        for name, mutate in changes:
            with self.subTest(name=name):
                b = deepcopy(self.bundle)
                mutate(b)
                with self.assertRaises(InvalidSnapshot):
                    export_intake(b)

    def test_deterministic_no_mutation_and_private_default_report(self):
        original = deepcopy(self.bundle)
        snap, manifest, _ = self.result()
        self.assertEqual(original, self.bundle)
        for key, value in self.bundle.items():
            if isinstance(value, list):
                value.reverse()
        self.assertEqual(export_intake(self.bundle), (snap, manifest))
        report = json.dumps(score(snap))
        for collection in ('requests', 'quotes', 'orders'):
            self.assertNotIn(snap[collection][0]['id'], report)
        self.assertNotIn('source_id', report)

    def test_cli_private_files_no_overwrite_and_no_data_in_errors(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source, dest = root/'input.json', root/'export'
            source.write_text(json.dumps(self.bundle))
            command = [sys.executable, str(HERE/'intake_export.py'), str(source), str(dest)]
            run = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            for path in (dest, *dest.iterdir()):
                self.assertEqual(stat.S_IMODE(path.stat().st_mode) & 0o077, 0)
            before = (dest/'snapshot.json').read_bytes()
            retry = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(retry.returncode, 2)
            self.assertEqual((dest/'snapshot.json').read_bytes(), before)
            for invalid in ('{"secret":"private-token"}', '{"intake_version":1,"intake_version":"private-token"}', '[]'):
                source.write_text(invalid)
                bad = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(bad.returncode, 2)
                self.assertNotIn('private-token', bad.stderr)
                self.assertEqual(bad.stdout, '')


if __name__ == '__main__':
    unittest.main()
