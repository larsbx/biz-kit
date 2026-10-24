ExUnit.start()

# Money currency metadata uses Localize, configured by the umbrella with an
# :eatsbot locale-cache owner. Load that OTP application's metadata without
# starting its web, database or queue supervision tree.
case Application.load(:eatsbot) do
  :ok -> :ok
  {:error, {:already_loaded, :eatsbot}} -> :ok
end

{:ok, _apps} = Application.ensure_all_started(:localize)
