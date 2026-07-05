defmodule AshEventsSpike.Notes do
  use Ash.Domain

  resources do
    resource AshEventsSpike.Notes.Note
    resource AshEventsSpike.Events.Event
  end
end
