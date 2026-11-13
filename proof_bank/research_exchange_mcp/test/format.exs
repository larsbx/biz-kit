root = Path.expand("..", __DIR__)

files =
  [Path.join(root, "mix.exs")] ++ Path.wildcard(Path.join(root, "{lib,test,bin}/**/*.{ex,exs}"))

bad =
  Enum.filter(files, fn path ->
    original = File.read!(path)
    formatted = IO.iodata_to_binary(Code.format_string!(original)) <> "\n"

    if "--check" in System.argv(),
      do: original != formatted,
      else:
        (
          File.write!(path, formatted)
          false
        )
  end)

if bad != [],
  do:
    (
      IO.puts(:stderr, Enum.join(bad, "\n"))
      System.halt(1)
    )
