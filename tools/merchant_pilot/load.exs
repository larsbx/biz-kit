# Load the same CommerceCore source modules without compiling/starting the umbrella.
root = Path.expand("../../apps/commerce_core/lib/commerce_core", __DIR__)

for name <- ~w(validation json scorecard intake cli) do
  Code.require_file(Path.join([root, "merchant_pilot", name <> ".ex"]))
end

Code.require_file(Path.join(root, "merchant_pilot.ex"))
