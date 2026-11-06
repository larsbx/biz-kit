Code.require_file("support.exs", __DIR__)
MerchantPilot.Formal.Replay.traces(System.argv()) |> MerchantPilot.Formal.Support.print()
