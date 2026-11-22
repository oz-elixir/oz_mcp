This is an Elixir application implementing a MCP server.

## GENERAL

### Temporary scripts

If temporary script is needed to help and it must be saved on filesystem:
- DO NOT use system wide /tmp/ folder (NEVER)
- Use ./tmp/ available in the project structure (ALWAYS)

## ELIXIR GUIDELINES

### Defining modules

- For all the code located in lib/ NEVER define multiple modules in one file
- For all the code located in lib/ ALWAYS define only one modules per files
- For all the code located in test/ it is allowed to define multiple modules per files.

### Elixir lists

**Do not support index based access via the access syntax**

**WRONG: Never do this (invalid):**

```elixir
i = 0
mylist = ["blue", "green"]
mylist[i]
```

**RIGHT: Instead do this (valid):**

Use `Enum.at`, pattern matching, or `List` for index based list access, ie:

```elixir
i = 0
mylist = ["blue", "green"]
Enum.at(mylist, i)
```

### Updating nested map

**WRONG: Never do this (invalid):**

```elixir
Map.update!(config, :resources_list_meta, fn m ->
  Map.put(m, key, value)
end)
```

**RIGHT: Instead do this (valid):**

```elixir
put_in(config, [:resources_list_meta, key], value)
```

## FORMATTING

### Keyword do/else on its own line

- NEVER leave `do:` (or `else:`) alone on a line with its body below it. When the body does not fit on the line of `do:`, use a `do ... end` block.

**RIGHT: Do this (valid):**

```elixir
def check!(other) do
  raise(ArgumentError, "'required_scopes' must be a list of strings, got: #{inspect(other)}")
end
```

```elixir
def check!(other), do: raise(ArgumentError, "Bad argument")
```

```elixir
def check!(other),
  do: raise(ArgumentError, "Bad argument for this call")
```

**WRONG: Never do this (invalid):**

```elixir
def check!(other),
  do:
    raise(ArgumentError, "'required_scopes' must be a list of strings, got: #{inspect(other)}")
```

```elixir
if valid?(name),
  do: :ok,
  else:
    {:error, "must be 1 to 128 characters of A-Z, a-z, 0-9, _, - and ., got: #{inspect(name)}"}
```

### Comments

- There are two kinds of comment blocks: the open block and the framed block. The line above the comment decides which one, at any depth (module level, function body, `case`/`with`/`rescue`/`catch` clauses...).
- Open block: the line above the comment is a blank line (the code without the comment would have a blank line there). It has NO first `#` frame line and it ALWAYS ends with a line `#`.
- Framed block: the line above the comment opens a block (`do`, `->`, `rescue`, `catch`, `else`, `with ... do`...), so the comment is the first line of that block (the code without the comment would have no blank line there). It ALWAYS starts with a line `#` and ends with a line `#`.
- The comment above a `defmodule` is ALWAYS a framed block.
- A comment on a declaration ALWAYS sits above the whole group (above `@doc`, `@spec`, `@impl`), never between `@doc` and the rest.
- A comment NEVER sits inside the head of a declaration (between `def name(...),` and its `do:`): it goes above the declaration as an open block. Join `def ..., do: ...` on one line when it fits.
- Exception: a banner (`# ----` / text / `# ----`) or a heading (`# ---- Text`) has NO `#` frame line and it ALWAYS has a blank line before and after it. When it is the first line of a `do` block (a `describe ... do`, for example), it has no blank line before it (the formatter removes it).
- A trailing comment (`code # text`) and a `#` line inside a heredoc are not comment blocks.

**RIGHT: Do this (valid):**

```elixir
  {:refuse, challenge, metadata_url} ->
    refuse(conn, instance, challenge, metadata_url)

  # The text of the comment
  #
  :not_running ->
```

```elixir
    |> put_private(:cors_origin, origin)

  # The text of the comment
  #
  Process.delete(@response_started_key)
```

```elixir

# The text of the comment
#
@spec auth(Context.t()) :: Pipeline.result()
```

```elixir

# The text of the comment
#
@doc false
@spec auth(Context.t()) :: Pipeline.result()
defp auth(context) do
```

```elixir

# The first paragraph.
#
# The second paragraph.
#
defp parsers(length) do
```

```elixir

# The text of the comment
#
@impl true
def aux_down(_reason, %{stream: stream}), do: {:halt, stream.conn}
```

```elixir
with {:ok, config} <- OzMcp.Instance.config(instance) do
  #
  # The text of the comment
  #
  conn = put_private(conn, :oz_mcp_config, config)
```

```elixir
rescue
  #
  # The text of the comment
  #
  Plug.Parsers.UnsupportedMediaTypeError ->
```

```elixir
error ->
  #
  # The first paragraph.
  #
  # The second paragraph.
  #
  if Plug.Exception.status(error) == 408 do
```

```elixir
#
# The text of the comment
#
defmodule OzMcp.Stream do
```

```elixir

# -------------------------------------------------------------------
# The text of the comment
# -------------------------------------------------------------------

```

```elixir

# ----------- The text of the comment

```

```elixir
describe "check!/1" do
  # -------------------------------------------------------------------
  # The text of the comment
  # -------------------------------------------------------------------

  test "..." do
```

**WRONG: Never do this (invalid):**

```elixir

#
# A framed block after a blank line
#
defp parsers(length) do
```

```elixir
    refuse(conn, instance, challenge, metadata_url)

  #
  # A framed block after a blank line
  #
  :not_running ->
```

```elixir
error ->
  # An open block as the first line of a block
  #
  if Plug.Exception.status(error) == 408 do
```

```elixir
catch
  # No frame line at all
  :exit, reason when reason in [:normal, :shutdown] ->
```

```elixir

# No last frame line
defp parsers(length) do
```

```elixir
@impl true
def aux_down(_reason, %{stream: stream}),
  #
  # A comment inside the head of a declaration
  #
  do: {:halt, stream.conn}
```

```elixir
@doc false
# A comment between @doc and the declaration
#
@spec auth(Context.t()) :: Pipeline.result()
```

```elixir

# An open block above a defmodule
#
defmodule OzMcp.Stream do
```

```elixir
#
# -------------------------------------------------------------------
# A frame on a banner
# -------------------------------------------------------------------
#
```

```elixir
# -------------------------------------------------------------------
# No blank line after the banner
# -------------------------------------------------------------------
@spec session(Context.t()) :: Pipeline.result()
```

```elixir
# ----------- No blank line after the heading
@spec auth(Context.t()) :: Pipeline.result()
```

### Moduledoc

- ALWAYS put a blank line after `@moduledoc` (with `false` or with content).

**RIGHT: Do this (valid):**

```elixir
defmodule OzMcp.Stream.Timers do
  @moduledoc false

  alias OzMcp.Stream.Loop
```

```elixir
defmodule OzMcp.Validate.Http do
  @moduledoc """
  The HTTP stages of the validation pipeline.
  """

  import Plug.Conn
```

**WRONG: Never do this (invalid):**

```elixir
defmodule OzMcp.Stream.Timers do
  @moduledoc false
  alias OzMcp.Stream.Loop
```

```elixir
defmodule OzMcp.Validate.Http do
  @moduledoc """
  The HTTP stages of the validation pipeline.
  """
  import Plug.Conn
```

### Moduledoc in lib/ (internal modules)

- For all the internal modules in lib/ ALWAYS put `@moduledoc false` (NEVER a `@moduledoc` with text).
- For all the internal modules in lib/ ALWAYS describe the module in a framed comment above its `defmodule`, NEVER inside the module.
- For all the internal modules in lib/ NEVER put a `@doc` with text on a function or a macro: describe it in a comment above the whole group (above `@spec`, `@impl`). `@doc false` stays allowed.
- A public doc or a guide that names an internal module NEVER puts the name in backticks (ExDoc would make a broken link): write OzMcp.Handler, not `` `OzMcp.Handler` ``.

**RIGHT: Do this (valid):**

```elixir
#
# The target of the messages of one request: the stream of a `POST`
# response, or a sink of a transport that has no HTTP response (stdio).
#
defmodule OzMcp.Stream do
  @moduledoc false

  @type t :: struct()
```

```elixir

# Returns the `outputSchema` of a tool, or `nil`.
#
@spec schema(struct() | nil) :: map() | nil
def schema(nil), do: nil
```

**WRONG: Never do this (invalid):**

```elixir
defmodule OzMcp.Stream do
  @moduledoc false

  #
  # The target of the messages of one request: the stream of a `POST`
  # response, or a sink of a transport that has no HTTP response (stdio).
  #

  @type t :: struct()
```

```elixir
#
# The target of the messages of one request: the stream of a `POST`
# response, or a sink of a transport that has no HTTP response (stdio).
#
defmodule OzMcp.Stream do
  @type t :: struct()
```

```elixir
defmodule OzMcp.Stream do
  @moduledoc """
  > #### Internal module {: .warning}
  >
  > Not part of the public API. It can change in any release.

  The target of the messages of one request.
  """
```

```elixir
defmodule OzMcp.Handler.Output do
  @moduledoc false

  @doc "Returns the `outputSchema` of a tool, or `nil`."
  @spec schema(struct() | nil) :: map() | nil
  def schema(nil), do: nil
```

### Moduledoc in test/ and bench/

- The modules of bench/ (bench/support/ and the `.exs` scripts) follow the rules of test/ below.
- For all the modules in test/ NEVER put a `@moduledoc` (neither with text nor `false`).
- For all the modules in test/ ALWAYS describe the module in a framed comment above its `defmodule`.
- For all the modules in test/ NEVER put a `@doc` with text on a function or a macro: describe it in a comment above the whole group (above `@spec`, `@impl`). `@doc false` stays allowed.
- Exception: a fixture whose test reads its moduledoc or the docs of its functions keeps them, with a comment above it that says why (`Support.Helpers.WireDocFixture`, `Support.Helpers.SpecGaps.HiddenModule`, `Support.Helpers.SpecGaps.Fixture`).

**RIGHT: Do this (valid):**

```elixir
#
# Test support tool that blocks the callback until the test opens the
# gate.
#
defmodule Support.Entities.Tools.GateTest do
  use OzMcp.Config.Tool, dsl?: false
```

**WRONG: Never do this (invalid):**

```elixir
defmodule Support.Entities.Tools.GateTest do
  @moduledoc """
  Test support tool that blocks the callback until the test opens the
  gate.
  """

  use OzMcp.Config.Tool, dsl?: false
```

```elixir
defmodule Support.Entities.Tools.GateTest do
  @moduledoc false

  use OzMcp.Config.Tool, dsl?: false
```
