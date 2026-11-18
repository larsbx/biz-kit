// Obligation (dispatch): concurrent authenticated assignments cannot create
// active driver/vehicle conflicts.
//
// Rule in code: Dispatch.Fleet.Assignment identities :one_active_per_operator
// (status = 'ACTIVE' AND operator_exclusive) and :one_active_per_vehicle /
// :one_active_per_trailer (status = 'ACTIVE' AND <id> IS NOT NULL), partial
// unique indexes PostgreSQL enforces under concurrent commits;
// Dispatch.Operations.Board refusal/1 names the conflicting driver or
// equipment. Tested by BoardTest "equipment on active trips" and
// EquipmentExclusivityConcurrencyTest. On the ledger path the same rule is
// DispatchCore.Admission's check at `activate`, run by the single appender
// (every operator exclusive there; CoopSubstrate.DispatchAssignmentsTest).
// Trailers follow the vehicle rule and are not modelled separately.
// Abstracted: two assignments, two drivers, two vehicles; commits serialize
// (the database's unique check), so interleaving is a sequence of steps.
module dispatch_spec {
  const GUARDED: bool
  val A = Set(0, 1)
  var status: int -> str
  var driver: int -> str
  var vehicle: int -> str
  var exclusive: int -> bool

  action init = {
    nondet d = A.setOfMaps(Set("d1", "d2")).oneOf()
    nondet v = A.setOfMaps(Set("v1", "v2")).oneOf()
    nondet x = A.setOfMaps(Set(true, false)).oneOf()
    all { status' = A.mapBy(_ => "PLANNED"), driver' = d, vehicle' = v, exclusive' = x }
  }

  def otherActive(i, p) = A.exists(j => j != i and status.get(j) == "ACTIVE" and p(j))
  def driverFree(i) = not(exclusive.get(i) and
    otherActive(i, j => exclusive.get(j) and driver.get(j) == driver.get(i)))
  def vehicleFree(i) = not(otherActive(i, j => vehicle.get(j) == vehicle.get(i)))

  action activate(i) = all {
    status.get(i) == "PLANNED",
    not(GUARDED) or (driverFree(i) and vehicleFree(i)),
    status' = status.set(i, "ACTIVE"), driver' = driver, vehicle' = vehicle, exclusive' = exclusive,
  }
  action finish(i) = all {
    status.get(i) == "ACTIVE",
    status' = status.set(i, "COMPLETED"), driver' = driver, vehicle' = vehicle, exclusive' = exclusive,
  }
  // Refused commands change nothing; stuttering also keeps verification deadlock-free.
  action stutter = all { status' = status, driver' = driver, vehicle' = vehicle, exclusive' = exclusive }
  action step = nondet i = A.oneOf() any { activate(i), finish(i), stutter }

  def bothActive = A.forall(i => status.get(i) == "ACTIVE")
  val obligation = bothActive implies all {
    not(exclusive.get(0) and exclusive.get(1) and driver.get(0) == driver.get(1)),
    vehicle.get(0) != vehicle.get(1),
  }
  val obligationWitness = not(bothActive)
}
module dispatch { import dispatch_spec(GUARDED = true).* }
module dispatch_control { import dispatch_spec(GUARDED = false).* }
