# Explicit, infrastructure-free suite. Never loaded by ordinary `mix test`.
# Run from apps/dispatch with:
# MIX_ENV=test mix run --no-start contract_test/test_helper.exs
if Mix.env() != :test, do: raise("Dispatch contract tests require MIX_ENV=test")

ExUnit.start()
Code.require_file("../test/extension_contract_test.exs", __DIR__)
Code.require_file("bootstrap_test.exs", __DIR__)
