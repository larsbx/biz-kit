# Regenerates contracts/openapi.json from the Phoenix router (Section 20).
# Run via `mix openapi.generate`; the openapi-diff CI gate runs the check
# variant and fails when the checked-in file has drifted.
{:ok, _} = Application.ensure_all_started(:open_api_spex)

path = Path.expand("../../../contracts/openapi.json", __DIR__)
json = DispatchWeb.OpenApiJson.encode()

File.mkdir_p!(Path.dirname(path))
File.write!(path, json)

IO.puts("Wrote #{path}")
