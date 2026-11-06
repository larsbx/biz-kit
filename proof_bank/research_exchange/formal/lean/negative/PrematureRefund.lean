import ResearchExchange

namespace ResearchExchange.Negative

def running : Reservation.State :=
  Reservation.start (Reservation.reserve (Reservation.initial 10) 5)

/-- Deliberately false: cancelling a running computation does not release its hold. -/
theorem cancelling_immediately_refunds :
    (Reservation.settle (Reservation.cancel running) 0).available = 10 := by
  decide

end ResearchExchange.Negative
