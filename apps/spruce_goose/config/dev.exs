import Config

# No secrets in version control: read from the environment, with clearly
# marked non-production development placeholders.
config :spruce_goose,
  token_signing_secret:
    System.get_env("TOKEN_SIGNING_SECRET", "dev-only-placeholder-not-a-secret-token-signing")

# Dev has no governed Systemwide SOP, so the boot-time adoption check has
# nothing real to compare against. Production and any deployment that serves
# requests keeps it on; see SpruceGoose.SopGate.verify_adoption/0.
config :spruce_goose, :verify_sop_adoption, false
