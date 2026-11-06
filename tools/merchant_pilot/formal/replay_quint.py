"""Replay synthetic Quint ITF states against the actual exporter and scorecard.
This is finite conformance evidence, not a theorem that Python refines Quint.
"""
import argparse
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from intake_export import export_intake
from scorecard import InvalidSnapshot, score

HERE = Path(__file__).resolve().parent
BASE = json.loads((HERE.parent / 'intake.synthetic.json').read_text())
COLLECTIONS = ('merchants', 'requests', 'invitations', 'quotes', 'fee_arrangements', 'orders', 'costs')


def date(day):
    return (datetime(2026, 1, 1, tzinfo=timezone.utc) + timedelta(days=day)).strftime('%Y-%m-%dT%H:%M:%SZ')


def optional(day):
    return None if day < 0 else date(day)


def bundle_from_state(s):
    b = deepcopy(BASE)
    b['as_of'] = date(s['now'])
    request = b['requests'][0]
    canonical = deepcopy(b['requests'][1])
    canonical['data'] = deepcopy(request['data'])
    canonical['data'].update(id=b['requests'][1]['data']['id'], withdrawn_at=None)
    request['data'].update(status='qualified' if s['qualified'] else 'duplicate' if s['duplicate'] else 'unreviewed',
                           qualified_at=date(0) if s['qualified'] else None, withdrawn_at=None,
                           duplicate_of=canonical['data']['id'] if s['duplicate'] else None)
    request['data']['consent']['sharing_revoked_at'] = (
        optional(s['requestEnd']) if s['qualified'] else date(s['now']) if not s['sharing'] else None)
    b['requests'] = [request, canonical]
    for row in b['requests']:
        row['data']['observed_through'] = b['as_of']
    invitation = b['invitations'][0]
    invitation['data'].update(invited_at=date(0), responded_at=optional(s['firstAt']))
    b['invitations'] = [invitation] if s['revision'] > 0 else []
    quotes = []
    for revision in range(1, s['revision'] + 1):
        row = b['quotes'][revision - 1]
        row['data'].update(issued_at=date(s['firstAt'] if revision == 1 else s['secondAt']),
                           expires_at=date(12), withdrawn_at=optional(s['firstEnd'] if revision == 1 else s['secondEnd']))
        quotes.append(row)
    b['quotes'] = quotes
    order = b['orders'][0]
    d = order['data']
    d.update(accepted_at=optional(s['acceptedAt']), promised_by=date(s['acceptedAt'] + 2),
             outcome='fulfilled' if s['deliveredAt'] >= 0 else 'pending', outcome_at=optional(s['deliveredAt']),
             paid_at=optional(s['paidAt']), returned_at=None, disputed_at=None,
             reconciled_at=optional(s['closedAt']), gross_minor=10000 if s['paidAt'] >= 0 else None,
             provider_verified=s['paidAt'] >= 0, observed_through=b['as_of'])
    d['quote_ref']['revision'] = s['accepted']
    refund = d['refunds'][0]
    refund.update(at=optional(s['refundAt']), minor=s['refund'])
    d['refunds'] = [refund] if s['refund'] else []
    for role, gross, partial in (('servicing_store', 250, 50), ('platform', 600, 100)):
        d['fees'][role] = dict(gross_minor=gross if s['paidAt'] >= 0 else 0,
                              reversed_minor=gross if s['refund'] == 10000 else partial if s['refund'] == 1000 else 0)
    b['orders'] = [order] if s['accepted'] > 0 else []
    costs = []
    role_field = dict(merchant='merchantKnown', servicing_store='storeKnown', platform='platformKnown')
    for row in b['costs']:
        pool = row['data']
        if pool['order_id'] is not None and s['accepted'] == 0:
            continue
        pool['complete'] = s['overheadKnown'] if pool['order_id'] is None else s[role_field[pool['role']]]
        for item in pool['items']:
            item['incurred_at'] = date(0 if pool['order_id'] is None else s['acceptedAt'])
        costs.append(row)
    b['costs'] = costs
    for row in b['coverage']:
        row['through'] = date(s['coverage'])
    for collection in COLLECTIONS:
        for row in b[collection]:
            row['captured_at'] = b['as_of']
    return b


def check_state(s, report):
    b = bundle_from_state(s)
    try:
        snapshot, _ = export_intake(b)
    except InvalidSnapshot as exc:
        if report['accepted'] or 'coverage' not in str(exc):
            raise
        return False
    assert report['accepted'], 'Quint refused a runtime-admissible snapshot'
    result = score(snapshot)
    # The second source request is the canonical duplicate anchor, with no quote/order.
    assert result['demand']['qualified_requests'] - 1 == report['requests']
    assert result['demand']['seven_day_match']['denominator'] - int(s['now'] >= 7) == report['denominator']
    assert result['demand']['seven_day_match']['numerator'] == report['matched']
    for role, field, value in (('merchant', 'merchantKnown', 'merchant'),
                               ('servicing_store', 'storeKnown', 'store'),
                               ('platform', 'platformKnown', 'platform')):
        actual = result['economics']['by_currency']['USD'][role]['scenarios'][0]['cohort_margin_minor']
        expected = report[value] if report[field] else None
        assert actual == expected, (role, actual, expected, s)
    return True


def decode(value):
    if isinstance(value, dict):
        if set(value) == {'#bigint'}:
            return int(value['#bigint'])
        return {key: decode(item) for key, item in value.items()}
    if isinstance(value, list):
        return [decode(item) for item in value]
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('traces', nargs='+', type=Path)
    args = parser.parse_args()
    total, admitted, unique = 0, 0, set()
    for path in args.traces:
        trace = decode(json.loads(path.read_text()))
        assert trace['states'], 'empty Quint trace'
        for state in trace['states']:
            total += 1
            admitted += check_state(state['s'], state['report'])
            unique.add(json.dumps(state['s'], sort_keys=True))
    print(json.dumps(dict(traces=len(args.traces), states=total, unique_states=len(unique),
                          admitted=admitted, coverage_refusals=total-admitted, dataset='synthetic')))


if __name__ == '__main__':
    main()
