ExUnit.start()

# CommerceCore's currency arithmetic needs Localize's loader at test time.
# Use the dependency's bundled English locale rather than Eatsbot's
# application-owned locale cache. No restaurant web/database app is started.
Application.put_env(:localize, :otp_app, :localize)
{:ok, _apps} = Application.ensure_all_started(:localize)
