#
# The configuration of one OzMcp instance: the options of the child
# spec, checked and frozen at boot.
#
defmodule OzMcp.Instance.Config do
  @moduledoc false

  alias OzMcp.Auth.Metadata
  alias OzMcp.Auth.Scopes
  alias OzMcp.Catalog
  alias OzMcp.Config.Completions
  alias OzMcp.Config.Duplicates
  alias OzMcp.Config.TaskSupport
  alias OzMcp.Config.ToolNames
  alias OzMcp.Instance.Config.Check
  alias OzMcp.Instance.Config.Schema
  alias OzMcp.Telemetry

  require Logger

  @enforce_keys [:name, :server, :transport]

  defstruct [
    :name,
    :server,
    :transport,
    :authorization,
    :telemetry,
    opts: %{}
  ]

  @type t :: %__MODULE__{}

  # The static opts of a server. They are published once, in the config of
  # the instance, when the server boots: reading them is a lock-free read
  # of the metadata of the Registry, never a call to a process. The map
  # holds one key for each option of the schema, plus the derived key
  # `resource_metadata_url`.
  #
  @type opts :: %{required(atom()) => term()}

  @transports [:http, :stdio]

  # The keys of the instance itself. Every other key of the input is an
  # option of the schema.
  #
  @instance_keys [:server, :name, :transport]

  @doc false
  @spec default_opts() :: map()
  def default_opts, do: Map.put(Schema.defaults(), :resource_metadata_url, nil)

  @spec parse!(keyword() | map()) :: t()
  def parse!(opts) when is_list(opts), do: opts |> Map.new() |> parse!()

  def parse!(%{server: server} = opts) when is_atom(server) do
    assert_module_is_loaded!(server)
    assert_no_unknown_opts!(opts)

    name = Map.get(opts, :name, server)
    transport = Map.get(opts, :transport, :http)
    assert_name!(name)
    assert_transport!(transport)

    server_opts =
      opts
      |> Map.drop(@instance_keys)
      |> then(&Map.merge(Schema.defaults(), &1))
      |> validate!(server)

    Duplicates.check!(server)
    ToolNames.check!(server)
    TaskSupport.check!(server)
    Completions.check!(server)

    # The catalog is built before the checks of the authorization: the
    # check of the orphan scopes reads the scopes of the static entities
    # from the catalog.
    #
    _ = Catalog.boot(server)

    case transport do
      :http ->
        assert_authorization_setup!(server, server_opts)

      :stdio ->
        if server_authorization(server) != nil do
          Logger.info(
            "server #{inspect(server)} declares an authorization block, " <>
              "which is not used on the stdio transport"
          )
        end
    end

    telemetry = Telemetry.new(name, server, server_opts.telemetry_prefix)
    server_opts = canonical_resource_url(server_opts, transport)

    server_opts =
      Map.put(server_opts, :resource_metadata_url, Metadata.url(server_opts.resource_url))

    %__MODULE__{
      name: name,
      server: server,
      transport: transport,
      opts: server_opts,
      telemetry: telemetry,
      authorization: server_authorization(server)
    }
  end

  def parse!(other),
    do: raise(ArgumentError, "OzMcp needs the option :server, got: #{inspect(other)}")

  defp assert_no_unknown_opts!(opts) do
    known = @instance_keys ++ Schema.keys()

    case opts |> Map.keys() |> Enum.reject(&(&1 in known)) |> Enum.sort() do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown option(s) for #{inspect(opts.server)}: #{inspect(unknown)}. " <>
                "Known options: #{inspect(Enum.sort(known))}"
    end
  end

  # One loop validates every option of the schema and gives the checked
  # map back: a check can also normalize its value (for example `nil`
  # becomes `[]` for `allowed_origins`). The relations compare two
  # options, so they run after the loop.
  #
  defp validate!(opts, server) do
    opts =
      Enum.reduce(Schema.rows(), opts, fn {key, _type, _default, _flags} = row, acc ->
        Map.put(acc, key, Check.value(row, Map.fetch!(acc, key), server))
      end)

    Enum.each(Schema.relations(), &Check.relation!(&1, opts))
    opts
  end

  # The `resource_url` of an HTTP server is published in its canonical form
  # (RFC 8707): the scheme and the host in lower case, no default port.
  #
  defp canonical_resource_url(%{resource_url: url} = opts, :http) when is_binary(url) do
    {:ok, canonical} = OzMcp.Auth.Audience.canonical(url)
    Map.put(opts, :resource_url, canonical)
  end

  defp canonical_resource_url(opts, _transport), do: opts

  defp assert_name!(name) when is_atom(name) and name not in [nil, true, false], do: :ok

  defp assert_name!(name) do
    raise(
      ArgumentError,
      "name must be an atom (not nil, true or false), got: #{inspect(name)}"
    )
  end

  defp assert_transport!(transport) when transport in @transports, do: :ok

  defp assert_transport!(other),
    do: raise(ArgumentError, "transport must be :http or :stdio, got: #{inspect(other)}")

  defp assert_module_is_loaded!(module) do
    unless Code.ensure_loaded?(module) do
      raise ArgumentError,
            "each server entry must be Module or {Module, opts}, got: #{inspect(module)}"
    end
  end

  defp assert_authorization_setup!(server, opts) do
    auth = server_authorization(server)
    resource_url = Map.get(opts, :resource_url)

    cond do
      auth != nil and is_nil(resource_url) ->
        raise ArgumentError,
              "server #{inspect(server)} declares an authorization block, " <>
                "its opts must set :resource_url"

      auth == nil and resource_url != nil ->
        raise ArgumentError,
              "server #{inspect(server)} sets :resource_url but declares no authorization block"

      true ->
        :ok
    end

    if auth != nil do
      assert_verifier!(server, auth)
      assert_resource_url!(resource_url)
    else
      assert_no_orphan_scopes!(server)
    end
  end

  defp assert_no_orphan_scopes!(server) do
    case Scopes.declared(server) do
      [] ->
        :ok

      scopes ->
        raise ArgumentError,
              "server #{inspect(server)} declares no authorization block, " <>
                "but its entities require the scopes #{inspect(scopes)}. " <>
                "Add an authorization block or remove required_scopes"
    end
  end

  defp server_authorization(server) do
    if Code.ensure_loaded?(server) and function_exported?(server, :authorization, 0),
      do: server.authorization(),
      else: nil
  end

  defp assert_verifier!(server, auth) do
    verifier = Map.get(auth, :verifier)

    cond do
      not (is_atom(verifier) and Code.ensure_loaded?(verifier)) ->
        raise ArgumentError,
              "server #{inspect(server)}: the authorization verifier #{inspect(verifier)} " <>
                "is not a loaded module"

      not function_exported?(verifier, :authenticate, 2) ->
        raise ArgumentError,
              "server #{inspect(server)}: the authorization verifier #{inspect(verifier)} " <>
                "must export authenticate/2"

      true ->
        :ok
    end
  end

  defp assert_resource_url!(url) do
    unless valid_resource_url?(url) do
      raise ArgumentError,
            ":resource_url must be a canonical URI " <>
              "(https scheme, or http for a loopback host (localhost, 127.0.0.1, ::1); " <>
              "no query, no fragment, no user info, no trailing slash), got: #{inspect(url)}"
    end
  end

  defp valid_resource_url?(url) when is_binary(url) do
    uri = URI.parse(url)

    canonical_scheme?(uri) and
      is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo) and
      is_nil(uri.query) and
      is_nil(uri.fragment) and
      no_trailing_slash?(uri.path)
  end

  defp valid_resource_url?(_url), do: false

  defp canonical_scheme?(%URI{scheme: scheme, host: host})
       when is_binary(scheme) and is_binary(host) and host != "" do
    String.downcase(scheme) == "https" or
      (String.downcase(scheme) == "http" and OzMcp.Auth.loopback_host?(host))
  end

  defp canonical_scheme?(_uri), do: false

  defp no_trailing_slash?(nil), do: true
  defp no_trailing_slash?("/"), do: true
  defp no_trailing_slash?(path), do: not String.ends_with?(path, "/")
end
