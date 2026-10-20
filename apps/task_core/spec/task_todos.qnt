// A task's todos (TaskCore.Todos; docs/architecture/2026-10-20-sprucegoose-salvage.md):
// an operator adds, revises, completes and drops them while the task is not
// finished, and the task completes only once none is open. Each action is
// one admitted ledger command; its preconditions are the append gate's
// checks. The rest of the lifecycle is task_lifecycle.qnt's; here the task
// is only open, completed or cancelled.
//
//   ./check.sh   (typecheck, sampled safety, witnesses, bounded Apalache check)
module task_todos {
  pure val TODOS = Set("a", "b", "c")

  // `state` is "absent" before it is added, then "open", "completed" or "dropped".
  type Todo = { state: str, deps: Set[str] }

  var todos: str -> Todo
  var task: str

  action init = all {
    todos' = TODOS.mapBy(_ => { state: "absent", deps: Set() }),
    task' = "open",
  }

  def open(i: str): bool = todos.get(i).state == "open"
  def present(i: str): bool = todos.get(i).state != "absent"
  // What a dependency may name: a todo added and not dropped.
  def nameable(i: str): bool = present(i) and todos.get(i).state != "dropped"

  // Todos reachable from `i` along dependencies, within |TODOS| steps.
  def reach(deps: str -> Set[str], i: str): Set[str] = {
    val one = deps.get(i)
    val two = one.union(flatten(one.map(j => deps.get(j))))
    two.union(flatten(two.map(j => deps.get(j))))
  }

  def acyclic(deps: str -> Set[str]): bool = TODOS.forall(i => not(reach(deps, i).contains(i)))

  def depsOf: str -> Set[str] = TODOS.mapBy(i => todos.get(i).deps)

  action unchanged = task' = task

  // TaskTodoAddedV1: depends only on todos already there, so no cycle.
  action add = {
    nondet i = TODOS.oneOf()
    nondet deps = TODOS.powerset().oneOf()
    all {
      task == "open", not(present(i)), deps.forall(j => nameable(j)),
      todos' = todos.set(i, { state: "open", deps: deps }), unchanged,
    }
  }

  // TaskTodoRevisedV1: an open todo's dependencies, never closing a cycle.
  action revise = {
    nondet i = TODOS.oneOf()
    nondet deps = TODOS.powerset().oneOf()
    all {
      task == "open", open(i), deps.forall(j => nameable(j)),
      acyclic(depsOf.set(i, deps)),
      todos' = todos.set(i, { state: "open", deps: deps }), unchanged,
    }
  }

  // TaskTodoCompletedV1: once, after its dependencies are completed or dropped.
  action complete = {
    nondet i = TODOS.oneOf()
    all {
      task == "open", open(i), todos.get(i).deps.forall(j => not(open(j))),
      todos' = todos.setBy(i, x => { ...x, state: "completed" }), unchanged,
    }
  }

  // TaskTodoDroppedV1: once no open todo depends on it.
  action drop = {
    nondet i = TODOS.oneOf()
    all {
      task == "open", open(i), TODOS.forall(j => not(open(j) and todos.get(j).deps.contains(i))),
      todos' = todos.setBy(i, x => { ...x, state: "dropped" }), unchanged,
    }
  }

  // TaskCompletedV1 (its other preconditions are task_lifecycle.qnt's).
  action finish = all { task == "open", TODOS.forall(i => not(open(i))), task' = "completed", todos' = todos }

  // TaskCancelledV1 / TaskCancelledByGovernanceV1: todos may still be open.
  action cancel = all { task == "open", task' = "cancelled", todos' = todos }

  action step = any { add, revise, complete, drop, finish, cancel }

  // -- safety -------------------------------------------------------------------

  val completedTaskHasNoOpenTodo = task == "completed" implies TODOS.forall(i => not(open(i)))

  val dependenciesNeverCycle = acyclic(depsOf)

  val dependenciesArePresent = TODOS.forall(i => todos.get(i).deps.forall(j => present(j)))

  // A todo is completed only after what it depends on; nothing depends on an
  // open todo's being dropped.
  val completedAfterDependencies = TODOS.forall(i =>
    todos.get(i).state == "completed" implies todos.get(i).deps.forall(j => not(open(j))))

  val droppedStrandsNothing = TODOS.forall(i =>
    todos.get(i).state == "dropped" implies TODOS.forall(j => not(open(j) and todos.get(j).deps.contains(i))))

  val safety = completedTaskHasNoOpenTodo and dependenciesNeverCycle and dependenciesArePresent
    and completedAfterDependencies and droppedStrandsNothing

  // -- witnesses: each must be violated, proving the state is reachable -----
  val noCompletedWithTodos = not(task == "completed" and TODOS.exists(i => present(i)))
  val noChain = not(TODOS.exists(i => reach(depsOf, i).size() == 2))
  val noDropped = TODOS.forall(i => todos.get(i).state != "dropped")
  val noCancelledWithOpenTodo = not(task == "cancelled" and TODOS.exists(i => open(i)))
}
