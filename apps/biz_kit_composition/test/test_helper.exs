ExUnit.start()

# Only the locale loader is necessary for Money's currency data.
Application.put_env(:localize, :otp_app, :localize)
{:ok, _apps} = Application.ensure_all_started(:localize)
