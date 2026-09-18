# Development seed data.
#
# Section 23.2 requires the six human role profiles to be seeded as versioned
# role definitions with immutable stable keys, and Section 21.1 permits
# `authorize?: false` in seed scripts. Slice 1 owns those resources, so this
# script currently seeds nothing and exists as the entry point they will use.
#
# Run with: mix run priv/repo/seeds.exs

IO.puts("No seed data yet; role definitions arrive with Slice 1.")
