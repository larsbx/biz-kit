"""Independent Python specification of MODEL_CONTRACT rev 1.

Only the sequential pure transition semantics are modelled. `trusted` is an
explicit assumption supplied to the model, not an implemented trust decision.
"""
from dataclasses import dataclass, replace
from enum import Enum
from typing import Optional, Union


@dataclass(frozen=True)
class Binding:
    target: int
    input: int
    environment: int
    policy: int


@dataclass(frozen=True)
class Candidate:
    worker: int
    generation: int
    binding: Binding
    artifact: int
    submittedAt: int
    leaseExpires: int


@dataclass(frozen=True)
class RewardConfig:
    expected: Binding
    reward: int
    workerA: int
    workerB: int

    def worker_allowed(self, worker: int) -> bool:
        return worker in (self.workerA, self.workerB)


class RewardPhase(str, Enum):
    OPEN = 'open'
    LEASED = 'leased'
    SUBMITTED = 'submitted'
    ACCEPTED = 'accepted'
    REJECTED = 'rejected'


@dataclass(frozen=True)
class RewardState:
    now: int
    generation: int
    owner: int
    expires: int
    phase: RewardPhase
    candidate: Optional[Candidate]
    payouts: int
    funder: int
    escrow: int
    balanceA: int
    balanceB: int

    @property
    def total(self) -> int:
        return self.funder + self.escrow + self.balanceA + self.balanceB


@dataclass(frozen=True)
class Tick:
    delta: int


@dataclass(frozen=True)
class Lease:
    worker: int
    deadline: int


@dataclass(frozen=True)
class Submit:
    worker: int
    generation: int
    binding: Binding
    artifact: int


@dataclass(frozen=True)
class Accept:
    trusted: bool
    evidence: Candidate


RewardAction = Union[Tick, Lease, Submit, Accept]


def initial_reward(config: RewardConfig, funder: int = 0,
                   balanceA: int = 0, balanceB: int = 0) -> RewardState:
    return RewardState(0, 0, config.workerA, 0, RewardPhase.OPEN, None,
                       0, funder, config.reward, balanceA, balanceB)


def reward_step(config: RewardConfig, state: RewardState,
                action: RewardAction) -> RewardState:
    """Apply one well-typed model action; guard failure returns the same state."""
    if isinstance(action, Tick):
        if state.phase == RewardPhase.REJECTED:
            return state
        return replace(state, now=state.now + action.delta)
    if isinstance(action, Lease):
        reusable = state.phase == RewardPhase.OPEN or (
            state.phase == RewardPhase.LEASED and state.now >= state.expires)
        if (config.worker_allowed(action.worker) and action.deadline > state.now
                and state.candidate is None and reusable):
            return replace(state, phase=RewardPhase.LEASED,
                           generation=state.generation + 1,
                           owner=action.worker, expires=action.deadline)
        return state
    if isinstance(action, Submit):
        if (state.phase == RewardPhase.LEASED and action.worker == state.owner
                and config.worker_allowed(action.worker)
                and action.generation == state.generation
                and state.now < state.expires and action.binding == config.expected
                and state.candidate is None):
            candidate = Candidate(action.worker, action.generation, action.binding,
                                  action.artifact, state.now, state.expires)
            return replace(state, phase=RewardPhase.SUBMITTED, candidate=candidate)
        return state
    if isinstance(action, Accept):
        c = state.candidate
        if (state.phase == RewardPhase.SUBMITTED and action.trusted
                and c is not None and action.evidence == c
                and action.evidence.binding == config.expected
                and config.worker_allowed(c.worker)
                and state.payouts == 0 and state.escrow >= config.reward):
            a = state.balanceA + (config.reward if c.worker == config.workerA else 0)
            b = state.balanceB + (config.reward if c.worker != config.workerA else 0)
            return replace(state, phase=RewardPhase.ACCEPTED, payouts=1,
                           escrow=state.escrow - config.reward, balanceA=a, balanceB=b)
        return state
    raise TypeError(f'unsupported reward action: {type(action).__name__}')


def reject_reward(config: RewardConfig, state: RewardState, evidence: Candidate) -> RewardState:
    """Apply a definitive decision after the adapter authenticates and fences it."""
    if (state.phase != RewardPhase.SUBMITTED or state.candidate != evidence
            or state.payouts != 0 or state.escrow != config.reward or config.reward == 0
            or evidence.binding != config.expected or not config.worker_allowed(evidence.worker)):
        return state
    return replace(state, phase=RewardPhase.REJECTED, escrow=0,
                   funder=state.funder + state.escrow)


class ReservationPhase(str, Enum):
    IDLE = 'idle'
    RESERVED = 'reserved'
    RUNNING = 'running'
    CANCELLING = 'cancelling'
    STOPPED = 'stopped'
    SETTLED = 'settled'


@dataclass(frozen=True)
class ReservationState:
    phase: ReservationPhase
    available: int
    held: int
    spent: int

    @property
    def total(self) -> int:
        return self.available + self.held + self.spent


@dataclass(frozen=True)
class Reserve:
    cap: int


@dataclass(frozen=True)
class Start:
    pass


@dataclass(frozen=True)
class Cancel:
    pass


@dataclass(frozen=True)
class Stop:
    trusted: bool


@dataclass(frozen=True)
class Settle:
    cost: int


ReservationAction = Union[Reserve, Start, Cancel, Stop, Settle]


def initial_reservation(credit: int) -> ReservationState:
    return ReservationState(ReservationPhase.IDLE, credit, 0, 0)


def reservation_step(state: ReservationState,
                     action: ReservationAction) -> ReservationState:
    if isinstance(action, Reserve):
        if state.phase == ReservationPhase.IDLE and action.cap <= state.available:
            return replace(state, phase=ReservationPhase.RESERVED,
                           available=state.available - action.cap,
                           held=state.held + action.cap)
        return state
    if isinstance(action, Start):
        return replace(state, phase=ReservationPhase.RUNNING) if (
            state.phase == ReservationPhase.RESERVED) else state
    if isinstance(action, Cancel):
        if state.phase == ReservationPhase.RESERVED:
            return replace(state, phase=ReservationPhase.STOPPED)
        if state.phase == ReservationPhase.RUNNING:
            return replace(state, phase=ReservationPhase.CANCELLING)
        return state
    if isinstance(action, Stop):
        if action.trusted and state.phase in (
                ReservationPhase.RUNNING, ReservationPhase.CANCELLING):
            return replace(state, phase=ReservationPhase.STOPPED)
        return state
    if isinstance(action, Settle):
        if state.phase == ReservationPhase.STOPPED and action.cost <= state.held:
            return ReservationState(ReservationPhase.SETTLED,
                                    state.available + state.held - action.cost,
                                    0, state.spent + action.cost)
        return state
    raise TypeError(f'unsupported reservation action: {type(action).__name__}')
