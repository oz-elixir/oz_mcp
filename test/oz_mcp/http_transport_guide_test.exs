#
# The guide about the HTTP transport must agree with the code on the
# servers that the CI runs and on the table of the status codes. The
# list of the statuses mirrors `OzMcp.Context.Error`.
#
defmodule OzMcp.HttpTransportGuideTest do
  use ExUnit.Case, async: true

  @guide Path.join(File.cwd!(), "guides/runtime/http_transport.md")

  # The status codes with the text that the row of the table must hold.
  # The list mirrors the statuses of `OzMcp.Context.Error`.
  #
  @statuses [
    {200, ["request", "stream", "DELETE"]},
    {202, ["notification", "response"]},
    {400, ["JSON", "session id", "visible ASCII", "protocol version", "authorization"]},
    {401, ["challenge"]},
    {403, ["origin", "scopes"]},
    {404, ["session", "path"]},
    {405, ["method"]},
    {406, ["Accept"]},
    {408, ["body", "read time"]},
    {413, ["max_body_bytes"]},
    {415, ["Content-Type"]},
    {429, ["limit", "restore"]},
    {500, ["internal"]},
    {503, ["instance", "read of the session failed"]}
  ]

  @http_servers [
    {"Bandit", "1.15.0", "test-e2e"},
    {"Cowboy", "2.21.0", "test-e2e-cowboy"}
  ]

  test "the supported servers of the guide are the jobs of the CI" do
    guide = File.read!(@guide)
    ci = File.read!(Path.join(File.cwd!(), ".github/workflows/ci.yml"))
    lock = File.read!(Path.join(File.cwd!(), "mix.lock"))

    for {name, version, job} <- @http_servers do
      assert guide =~ name, "the guide does not name #{name}"
      assert ci =~ "#{job}:", "the CI workflow has no job #{job}"
      assert lock =~ ~s("#{version}"), "mix.lock has no #{name} #{version}"
    end
  end

  test "the status table agrees with the statuses of the context error" do
    statuses = Regex.scan(~r/\| `(\d{3})` \|/, File.read!(@guide)) |> List.flatten()
    documented = statuses |> Enum.reject(&(&1 == "| `")) |> Enum.uniq()

    for {status, _parts} <- @statuses do
      assert to_string(status) in documented, "the status table has no row for #{status}"
    end
  end
end
