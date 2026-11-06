"""Project private, source-owned online intake extracts to scorecard v1. No network I/O."""

import argparse
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

from scorecard import (InvalidSnapshot, ROLES, amount, currency, fields, occurred,
                       require, rows, score, timestamp, token, unique, unique_object)

COLLECTIONS = ('merchants', 'requests', 'invitations', 'quotes', 'fee_arrangements',
               'orders', 'costs')
ENVELOPE = 'source_id owner_id record_id revision captured_at evidence_refs data'
COST_KINDS = {'acquisition', 'processing', 'inspection', 'storage', 'handling', 'shipping',
              'fraud', 'returns', 'support', 'operations', 'insurance', 'other'}


def flag(value):
    require(type(value) is bool, 'expected an explicit boolean')


def integer(value):
    require(type(value) is int and value > 0, 'expected a positive integer')


def evidence(value):
    require(isinstance(value, list) and len(value) > 0, 'evidence reference required')
    for key in value:
        token(key)
    require(len(value) == len(set(value)), 'duplicate evidence reference')


def opaque_ref(value):
    fields(value, 'source_id record_id revision', 'quote reference')
    token(value['source_id'])
    token(value['record_id'])
    integer(value['revision'])
    return value['source_id'], value['record_id'], value['revision']


def quote_key(pilot_id, row):
    # Stable opaque revision ID; input keys MUST themselves be random local tokens.
    value = [pilot_id, row['source_id'], row['owner_id'], row['record_id'], row['revision']]
    return hashlib.sha256(json.dumps(value, separators=(',', ':')).encode()).hexdigest()[:32]


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def export_intake(bundle):
    """Return (strict scorecard snapshot, private provenance/coverage manifest).

    Reject incomplete source coverage rather than treating absent outcomes as negative evidence.
    Financial amounts are observations at the declared cutoff, never scheduled fee estimates.
    """
    fields(bundle, 'intake_version dataset pilot cohort_started_at as_of coverage ' + ' '.join(COLLECTIONS),
           'intake bundle')
    require(type(bundle['intake_version']) is int and bundle['intake_version'] == 1,
            'unsupported intake version')
    require(bundle['dataset'] in ('synthetic', 'observed'), 'invalid dataset classification')
    start, cutoff = timestamp(bundle['cohort_started_at']), timestamp(bundle['as_of'])
    require(start <= cutoff, 'invalid observation interval')
    pilot = bundle['pilot']
    fields(pilot, 'id geography category approval_ref', 'pilot scope')
    for key in ('id', 'geography', 'category'):
        token(pilot[key])
    if pilot['approval_ref'] is not None:
        token(pilot['approval_ref'])
    require(bundle['dataset'] == 'synthetic' or pilot['approval_ref'] is not None,
            'observed export requires scope and participant approval reference')

    coverage = {}
    for row in rows(bundle['coverage'], 'coverage'):
        fields(row, 'source_id owner_id collection from through evidence_ref', 'source coverage')
        for name in ('source_id', 'owner_id', 'evidence_ref'):
            token(row[name])
        require(row['collection'] in COLLECTIONS, 'unknown source collection')
        require(timestamp(row['from']) <= start and timestamp(row['through']) >= cutoff,
                'source coverage does not cover the cohort cutoff; re-extract at a common cutoff')
        unique(coverage, (row['source_id'], row['collection']), row['owner_id'])
    require({collection for _, collection in coverage} == set(COLLECTIONS),
            'coverage attestation required for every collection, including empty streams')

    records, crosswalk = {}, []
    for collection in COLLECTIONS:
        records[collection] = []
        seen = {}
        for row in rows(bundle[collection], collection):
            fields(row, ENVELOPE, 'source record')
            for key in ('source_id', 'owner_id', 'record_id'):
                token(row[key])
            integer(row['revision'])
            occurred(row['captured_at'], start, cutoff)
            evidence(row['evidence_refs'])
            require(coverage.get((row['source_id'], collection)) == row['owner_id'],
                    'record outside declared source-owner boundary')
            unique(seen, (row['source_id'], row['record_id'], row['revision']), True)
            require(isinstance(row['data'], dict), 'record data must be an object')
            records[collection].append(row)
            crosswalk.append(dict(collection=collection, **deepcopy(row)))
        if collection != 'quotes':
            # Latest source snapshot only. No last-write-wins merge of authority records.
            keys = [(r['source_id'], r['record_id']) for r in records[collection]]
            require(len(keys) == len(set(keys)), 'ambiguous source record revisions')

    merchants = {}
    businesses = set()
    for row in records['merchants']:
        d = row['data']
        fields(d, 'id business_id opted_in_at withdrawn_at participation_ref', 'merchant participation')
        for key in ('id', 'business_id', 'participation_ref'):
            token(d[key])
        require(row['owner_id'] == d['id'], 'merchant participation must be source-owned')
        require(d['business_id'] not in businesses, 'merchant branches must use one canonical business identity')
        businesses.add(d['business_id'])
        opted = occurred(d['opted_in_at'], start, cutoff)
        occurred(d['withdrawn_at'], opted, cutoff, optional=True)
        unique(merchants, d['id'], d)

    def active_merchant(key, at):
        token(key)
        require(key in merchants, 'unknown merchant identity')
        m = merchants[key]
        instant = timestamp(at)
        require(timestamp(m['opted_in_at']) <= instant and
                (m['withdrawn_at'] is None or instant < timestamp(m['withdrawn_at'])),
                'merchant had not opted in or had withdrawn')

    snapshot = dict(schema_version=1, dataset=bundle['dataset'],
                    cohort_started_at=bundle['cohort_started_at'], as_of=bundle['as_of'],
                    requests=[], invitations=[], quotes=[], orders=[], unallocated_costs=[])
    all_requests, admitted, excluded = {}, {}, {}
    for row in records['requests']:
        d = row['data']
        fields(d, 'id buyer_key geography category specification_ref condition_ref quantity needed_by '
               'budget_minor currency submitted_at qualified_at status duplicate_of withdrawn_at '
               'consent observed_through', 'buyer request')
        for key in ('id', 'buyer_key', 'geography', 'category', 'specification_ref', 'condition_ref'):
            token(d[key])
        integer(d['quantity'])
        amount(d['budget_minor'], nullable=True)
        currency(d['currency'])
        submitted = occurred(d['submitted_at'], start, cutoff)
        require(timestamp(d['needed_by']) >= submitted, 'request deadline precedes submission')
        require(d['status'] in ('qualified', 'rejected', 'duplicate', 'unreviewed'), 'invalid qualification status')
        if d['duplicate_of'] is not None:
            token(d['duplicate_of'])
        require((d['status'] == 'duplicate') == (d['duplicate_of'] is not None),
                'duplicate request requires canonical request link')
        consent = d['consent']
        fields(consent, 'revision_ref granted_at sharing_revoked_at measurement_authorized', 'consent')
        token(consent['revision_ref'])
        grant = occurred(consent['granted_at'], submitted, cutoff, optional=True)
        revoked = occurred(consent['sharing_revoked_at'], grant or submitted, cutoff, optional=True)
        flag(consent['measurement_authorized'])
        qualified = occurred(d['qualified_at'], submitted, cutoff, optional=True)
        withdrawal = occurred(d['withdrawn_at'], qualified or submitted, cutoff, optional=True)
        unique(all_requests, d['id'], d)
        if d['status'] != 'qualified':
            require(qualified is None, 'excluded submission cannot have a qualification timestamp')
            excluded[d['id']] = d['status']
            continue
        require(d['geography'] == pilot['geography'] and d['category'] == pilot['category'],
                'qualified request outside approved scope')
        require(qualified is not None and grant is not None and grant <= qualified and
                (revoked is None or qualified < revoked), 'qualification requires current sharing consent')
        require(consent['measurement_authorized'],
                'historical measurement retention needs explicit source-owner authorization')
        require(timestamp(d['observed_through']) >= cutoff, 'request follow-up ends before cutoff')
        ends = [value for value in (withdrawal, revoked) if value is not None]
        effective = min(ends).strftime('%Y-%m-%dT%H:%M:%SZ') if ends else None
        result = dict(id=d['id'], qualified_at=d['qualified_at'], withdrawn_at=effective)
        snapshot['requests'].append(result)
        admitted[d['id']] = (d, result)
    for d in all_requests.values():
        if d['duplicate_of'] is not None:
            require(d['duplicate_of'] in admitted, 'duplicate must reference an admitted canonical request')
            original = admitted[d['duplicate_of']][0]
            require(original['buyer_key'] == d['buyer_key'], 'duplicate buyer identity mismatch')

    pairs = {}
    for row in records['invitations']:
        d = row['data']
        fields(d, 'request_id merchant_id invited_at responded_at', 'invitation')
        require(d['request_id'] in admitted, 'invitation references excluded request')
        active_merchant(d['merchant_id'], d['invited_at'])
        unique(pairs, (d['request_id'], d['merchant_id']), True)
        snapshot['invitations'].append(deepcopy(d))

    quotes, chains = {}, {}
    for row in records['quotes']:
        d = row['data']
        fields(d, 'request_id merchant_id issued_at expires_at withdrawn_at qualified currency '
               'price_minor tax_minor shipping_minor buyer_fee_minor supersedes_revision '
               'item_evidence_ref stock_evidence_ref', 'quote revision')
        require(row['owner_id'] == d['merchant_id'], 'quote outside merchant source ownership')
        require(d['request_id'] in admitted, 'quote references excluded request')
        for key in ('item_evidence_ref', 'stock_evidence_ref'):
            token(d[key])
        active_merchant(d['merchant_id'], d['issued_at'])
        for key in ('price_minor', 'tax_minor', 'shipping_minor', 'buyer_fee_minor'):
            amount(d[key])
        # v1 supplier-funded fee model cannot represent a separate buyer fee.
        require(d['buyer_fee_minor'] == 0, 'buyer-direct fees unsupported by scorecard v1')
        require(d['currency'] == admitted[d['request_id']][0]['currency'], 'quote/request currencies differ')
        q = {key: d[key] for key in ('request_id', 'merchant_id', 'issued_at', 'expires_at',
                                     'withdrawn_at', 'qualified', 'currency')}
        q.update(id=quote_key(pilot['id'], row), all_in_minor=sum(d[key] for key in
                 ('price_minor', 'tax_minor', 'shipping_minor', 'buyer_fee_minor')))
        unique(quotes, (row['source_id'], row['record_id'], row['revision']), (q, row))
        chains.setdefault((row['source_id'], row['record_id']), []).append((row, q))
        snapshot['quotes'].append(q)
    for chain in chains.values():
        chain.sort(key=lambda pair: pair[0]['revision'])
        first = chain[0][0]
        require(first['revision'] == 1 and first['data']['supersedes_revision'] is None,
                'quote history must start at original revision')
        for (prev, old), (row, new) in zip(chain, chain[1:]):
            require(row['revision'] == prev['revision'] + 1 and
                    row['data']['supersedes_revision'] == prev['revision'], 'quote history has a revision gap')
            require((row['owner_id'], new['merchant_id'], new['request_id']) ==
                    (prev['owner_id'], old['merchant_id'], old['request_id']), 'quote revision identity changed')
            require(timestamp(old['issued_at']) < timestamp(new['issued_at']), 'quote revisions out of order')
            old['withdrawn_at'] = min(t for t in (old['withdrawn_at'], new['issued_at']) if t is not None)

    arrangements = {}
    for row in records['fee_arrangements']:
        d = row['data']
        fields(d, 'id merchant_id servicing_store_id currency payer valid_from valid_until terms_ref',
               'fee arrangement')
        for key in ('id', 'terms_ref'):
            token(d[key])
        active_merchant(d['merchant_id'], d['valid_from'])
        if d['servicing_store_id'] is not None:
            active_merchant(d['servicing_store_id'], d['valid_from'])
        currency(d['currency'])
        require(d['payer'] == 'merchant', 'only supplier-funded fees supported')
        require(timestamp(d['valid_from']) < timestamp(d['valid_until']), 'invalid fee arrangement interval')
        unique(arrangements, d['id'], d)

    costs = {}
    cost_ids = set()
    for row in records['costs']:
        d = row['data']
        fields(d, 'order_id role currency complete items', 'cost pool')
        if d['order_id'] is not None:
            token(d['order_id'])
        require(d['role'] in ROLES, 'invalid cost role')
        currency(d['currency'])
        flag(d['complete'])
        total, known = 0, d['complete']
        for item in rows(d['items'], 'cost items'):
            fields(item, 'id kind minor incurred_at evidence_ref', 'cost item')
            token(item['id'])
            token(item['evidence_ref'])
            require(item['id'] not in cost_ids, 'expense allocated more than once')
            cost_ids.add(item['id'])
            require(item['kind'] in COST_KINDS, 'unsupported cost category')
            amount(item['minor'], nullable=True)
            occurred(item['incurred_at'], start, cutoff)
            known = known and item['minor'] is not None
            total += item['minor'] or 0
        unique(costs, (d['order_id'], d['role'], d['currency']), total if known else None)

    order_ids = set()
    order_currencies = {}
    for row in records['orders']:
        d = row['data']
        fields(d, 'id quote_ref servicing_store_id currency accepted_at promised_by outcome outcome_at '
               'paid_at returned_at disputed_at reconciled_at gross_minor refunds fees fee_arrangement_id '
               'stock_terms_revalidated provider_verified observed_through', 'accepted order')
        token(d['id'])
        require(d['id'] not in order_ids, 'duplicate order identity')
        order_ids.add(d['id'])
        order_currencies[d['id']] = d['currency']
        ref = opaque_ref(d['quote_ref'])
        require(ref in quotes, 'unknown accepted quote revision')
        q, _ = quotes[ref]
        active_merchant(q['merchant_id'], d['accepted_at'])
        flag(d['stock_terms_revalidated'])
        flag(d['provider_verified'])
        require(d['stock_terms_revalidated'], 'acceptance lacks stock and terms revalidation')
        require(d['paid_at'] is None or d['provider_verified'], 'payment requires independent provider verification')
        require(timestamp(d['observed_through']) >= cutoff, 'order follow-up ends before cutoff')
        token(d['fee_arrangement_id'])
        require(d['fee_arrangement_id'] in arrangements, 'unknown fee arrangement')
        a = arrangements[d['fee_arrangement_id']]
        require((a['merchant_id'], a['servicing_store_id'], a['currency']) ==
                (q['merchant_id'], d['servicing_store_id'], d['currency']), 'fee arrangement identity mismatch')
        require(timestamp(a['valid_from']) <= timestamp(d['accepted_at']) < timestamp(a['valid_until']),
                'fee arrangement not active at acceptance')
        if d['servicing_store_id'] is not None:
            active_merchant(d['servicing_store_id'], d['accepted_at'])
        refunds = []
        for refund in rows(d['refunds'], 'refunds'):
            fields(refund, 'id at minor evidence_ref provider_verified', 'verified refund')
            token(refund['evidence_ref'])
            flag(refund['provider_verified'])
            require(refund['provider_verified'], 'refund requires provider verification')
            refunds.append({key: refund[key] for key in ('id', 'at', 'minor')})
        keep = 'id servicing_store_id currency accepted_at promised_by outcome outcome_at paid_at returned_at disputed_at reconciled_at gross_minor fees'.split()
        out = {key: deepcopy(d[key]) for key in keep}
        out.update(quote_id=q['id'], refunds=refunds, costs_minor={
            role: costs.get((d['id'], role, d['currency'])) for role in ROLES})
        # Absence of a service store is an explicit fact; no money or costs can attach to it.
        if d['servicing_store_id'] is None:
            store_pool = (d['id'], 'servicing_store', d['currency'])
            require(store_pool not in costs or costs[store_pool] == 0,
                    'unknown or nonzero expense attributed to absent store')
            out['costs_minor']['servicing_store'] = 0
        snapshot['orders'].append(out)
    for order_id, _, code in costs:
        require(order_id is None or order_id in order_ids, 'cost references unknown order')
        require(order_id is None or code == order_currencies[order_id], 'expense/order currencies differ')
    codes = {d['currency'] for d in snapshot['quotes']} | {code for _, _, code in costs}
    for code in sorted(codes):
        for role in ROLES:
            snapshot['unallocated_costs'].append(dict(currency=code, role=role,
                                                      minor=costs.get((None, role, code))))
    for collection in ('requests', 'quotes', 'orders'):
        snapshot[collection].sort(key=lambda d: d['id'])
    snapshot['invitations'].sort(key=lambda d: (d['request_id'], d['merchant_id']))
    score(snapshot)  # The existing consumer is the final contract and temporal validator.
    crosswalk.sort(key=lambda r: (r['collection'], r['source_id'], r['record_id'], r['revision']))
    manifest = dict(intake_version=1, dataset=bundle['dataset'], pilot=deepcopy(pilot),
                    as_of=bundle['as_of'], coverage=sorted(deepcopy(bundle['coverage']),
                    key=lambda r: (r['collection'], r['source_id'])),
                    excluded_requests=excluded, records=crosswalk,
                    quote_ids=[dict(source_id=k[0], record_id=k[1], revision=k[2], scorecard_id=v[0]['id'])
                               for k, v in sorted(quotes.items())],
                    snapshot_sha256=hashlib.sha256(canonical(snapshot)).hexdigest())
    return snapshot, manifest


def write_export(destination, snapshot, manifest):
    """Write a new private directory; remove partial results on failure, never overwrite."""
    require(not destination.exists(), 'export destination already exists')
    stage = Path(tempfile.mkdtemp(prefix='.pilot-export-', dir=destination.parent))
    try:
        for name, data in (('snapshot.json', snapshot), ('provenance.private.json', manifest)):
            path = stage / name
            with path.open('x', encoding='utf-8') as target:
                os.chmod(path, 0o600)
                target.write(json.dumps(data, indent=2, sort_keys=True) + '\n')
        # mkdir+rename into a preexisting destination is disallowed above, but guard races too.
        destination.mkdir(mode=0o700)
        try:
            for path in stage.iterdir():
                path.rename(destination / path.name)
        except BaseException:
            shutil.rmtree(destination)
            raise
    finally:
        shutil.rmtree(stage)


def assemble(control, prepared_records):
    """Join approved online source extracts; do not assign authority or update records."""
    fields(control, 'intake_version dataset pilot cohort_started_at as_of coverage', 'export control')
    bundle = dict(deepcopy(control), **{name: [] for name in COLLECTIONS})
    for prepared in prepared_records:
        fields(prepared, 'collection record', 'prepared source extract')
        require(prepared['collection'] in COLLECTIONS, 'unknown record collection')
        bundle[prepared['collection']].append(deepcopy(prepared['record']))
    return bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('intake', type=Path)
    parser.add_argument('destination', type=Path, help='new private export directory')
    parser.add_argument('--records', type=Path, help='directory of approved online source extracts; input is export control')
    args = parser.parse_args()
    try:
        with args.intake.open(encoding='utf-8') as source:
            bundle = json.load(source, object_pairs_hook=unique_object)
        if args.records is not None:
            prepared = []
            for path in sorted(args.records.glob('*.json')):
                with path.open(encoding='utf-8') as source:
                    prepared.append(json.load(source, object_pairs_hook=unique_object))
            require(args.records.is_dir(), 'source record directory missing')
            bundle = assemble(bundle, prepared)
        snapshot, manifest = export_intake(bundle)
        write_export(args.destination, snapshot, manifest)
    except (InvalidSnapshot, OSError, UnicodeError, ValueError, TypeError, KeyError, OverflowError):
        parser.exit(2, 'Intake export refused. Check schema, evidence, scope and common cutoff privately.\n')
    print('Created private snapshot and provenance manifest; no commercial outcome inferred.')


if __name__ == '__main__':
    main()
