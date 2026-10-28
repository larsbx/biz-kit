# Elixir/OTP compatibility of portable biz-kit policy cores

A standalone Eatsbot deployment uses Elixir 1.18.4 and OTP 26.2.5.21,
whereas the main biz-kit umbrella currently compiles under Elixir 1.19.0 and
OTP 27.3.4. Five independent policy packages historically declared 1.19 and
therefore could not be vendored by Eatsbot without an Elixir toolchain upgrade.

This change broadens only the five **pure portable core** package version
requirements to Elixir 1.18. Their independent-host tests on OTP 26/Elixir
1.18 are required in addition to the existing OTP 27/Elixir 1.19 matrix.
Each test copies an app outside the umbrella before compilation, so it
cannot rely on the umbrella's project paths or dependency lock.

The Eatsbot deployment **does not** automatically use these packages; a
follow-up must pin verified revisions as dependencies and run actual
Eatsbot production-image, database and checkout acceptance. Cross-runtime
module compilation does not prove that a running Fly service is compatible
with biz-kit's newer Ash/Phoenix dependencies. The shared business policy
modules also do not become an authoritative order or stock writer merely
because they are dependency-compatible.

If the OTP 26 matrix fails, do not claim Eatsbot can vendor these cores;
repair the incompatibilities or keep a deliberate version split.
