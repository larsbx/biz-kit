ExUnit.start()

if System.get_env("HAWALA_TEST_SERVICE_BIN") == nil do
  ExUnit.configure(exclude: [rust_endpoint: true])
end
