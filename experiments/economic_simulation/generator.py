"""Reproducible explicit lots and requests; no empirical calibration."""
import random
from .scenario import ScenarioError, validate_scenario

def generate_market(seed=0,requests=100,suppliers=5,feasible_suppliers=2,areas=None,categories=None,intake_hours=672):
    for name,value in (("seed",seed),("requests",requests),("suppliers",suppliers),("feasible_suppliers",feasible_suppliers),("intake_hours",intake_hours)):
        if type(value) is not int or value<0:
            raise ScenarioError(f"{name} must be a nonnegative integer")
    if feasible_suppliers>suppliers:
        raise ScenarioError("feasible_suppliers cannot exceed suppliers")
    if requests>1000 or suppliers>100 or intake_hours>8760:
        raise ScenarioError("generator budget: 1000 requests, 100 suppliers, 8760 intake hours")
    areas=["metro-a"] if areas is None else areas
    categories=["materials"] if categories is None else categories
    if not isinstance(areas,list) or not areas or not isinstance(categories,list) or not categories:
        raise ScenarioError("areas and categories must be nonempty lists")
    if any(not isinstance(v,str) for v in areas+categories) or len(set(areas))!=len(areas) or len(set(categories))!=len(categories):
        raise ScenarioError("areas and categories must contain distinct strings")
    if len(areas)*len(categories)*max(suppliers,1)*max(requests,1)>50000:
        raise ScenarioError("generated market exceeds default candidate pair budget")
    rng=random.Random(seed)
    buyers=max(1,min(requests,20))
    businesses=[{"id":f"buyer-{i}"} for i in range(buyers)]
    businesses += [{"id":f"supplier-{i}","response_probability":0.8,"response_delay_hours":[2,24,48][i%3],"fulfillment_probability":0.95} for i in range(suppliers)]
    offers=[{"id":f"lot-{i}-{area}-{category}","seller_id":f"supplier-{i}","category":category,"area":area,"unit":"lot","quantity":max(1,(requests+max(1,suppliers)-1)//max(1,suppliers)),"available_at_hour":0,"expires_at_hour":intake_hours+336,"unit_price_minor":1000+50*i,"delivery_hours":48} for area in areas for category in categories for i in range(suppliers)]
    demand=[]
    for i in range(requests):
        area,category=rng.choice(areas),rng.choice(categories)
        hour=rng.randrange(intake_hours+1)
        demand.append({"id":f"request-{i:04}","buyer_id":f"buyer-{i%buyers}","category":category,"area":area,"unit":"lot","quantity":1,"qualified_at_hour":hour,"due_at_hour":hour+168,"max_unit_price_minor":20000,"acceptable_offer_ids":[f"lot-{j}-{area}-{category}" for j in sorted(rng.sample(range(suppliers),feasible_suppliers))]})
    return validate_scenario({"schema_version":"1.0","scenario_id":f"demand-{seed}-{requests}-{suppliers}-{feasible_suppliers}","description":"Uncalibrated synthetic demand-first market. Every scope has distinct physical stock lots.","start_at":"2026-01-01T00:00:00Z","observed_until_hour":intake_hours+168,"currency":"USD","annual_membership_fee_minor":25000,"businesses":businesses,"requests":demand,"offers":offers,"policy":{"coordination_cost_minor_per_order":100}})

def barter_ring(participants=5,failing_supplier=None):
    if type(participants) is not int or not 2<=participants<=100:
        raise ScenarioError("ring generator requires 2 to 100 participants")
    if failing_supplier is not None and (type(failing_supplier) is not int or not 0<=failing_supplier<participants):
        raise ScenarioError("failing_supplier must index a participant")
    businesses=[{"id":f"producer-{i}","response_delay_hours":0,"fulfillment_probability":0.0 if i==failing_supplier else 1.0} for i in range(participants)]
    offers=[{"id":f"supply-{i}","seller_id":f"producer-{i}","category":f"product-{i}","area":"metro-a","unit":"lot","quantity":1,"available_at_hour":0,"expires_at_hour":max(336,6*participants+168),"unit_price_minor":1000,"delivery_hours":6*(i+1)} for i in range(participants)]
    demand=[{"id":f"need-{i}","buyer_id":f"producer-{i}","category":f"product-{(i-1)%participants}","area":"metro-a","unit":"lot","quantity":1,"qualified_at_hour":0,"due_at_hour":max(168,6*participants),"max_unit_price_minor":2000,"exchange_offer_id":f"supply-{i}"} for i in range(participants)]
    return validate_scenario({"schema_version":"1.0","scenario_id":f"barter-ring-{participants}","description":"Independent supply/need slots; staggered physical legs can leave an exchange partially performed.","start_at":"2026-01-01T00:00:00Z","observed_until_hour":max(168,6*participants),"currency":"USD","businesses":businesses,"offers":offers,"requests":demand,"policy":{"mechanism":"barter","max_cycle_length":None}})

