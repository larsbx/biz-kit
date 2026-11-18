ExUnit.start()
ExUnit.after_suite(fn _ ->
  CoopSubstrate.LogCase.truncate_store!()
  CoopSubstrate.LogCase.truncate_records!()
end)
