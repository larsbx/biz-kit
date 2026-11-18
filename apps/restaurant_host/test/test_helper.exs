# Money needs Localize. The umbrella's shared config points Localize at the
# legacy eatsbot's locale cache, which this app does not load; use the
# dependency's bundled English locale and start the host only after that.
Application.put_env(:localize, :otp_app, :localize)
{:ok, _} = Application.ensure_all_started(:restaurant_host)
ExUnit.start()
