defmodule OzMcp.Auth.Scopes do
  @moduledoc """
  The scopes that a tool, a resource, a template or a prompt requires.

  A list of required scopes means "all of them". The data lives in the
  field `required_scopes` of the struct of the entity. A map entity
  carries them like a struct: the boot of the instance reads the key
  and checks it and the key never reaches the client.
  """

  alias OzMcp.Auth.Principal
  alias OzMcp.Catalog

  @doc """
  Check the value of a `required_scopes` declaration and return the scopes
  with no repeated entry. Raises `ArgumentError`.
  """
  @spec check!(term()) :: [String.t()]
  def check!([_ | _] = scopes) do
    if token_list?(scopes) do
      Enum.uniq(scopes)
    else
      raise ArgumentError,
            "'required_scopes' entries must match the RFC 6749 scope-token syntax, " <>
              "got: #{inspect(scopes)}"
    end
  end

  def check!([]),
    do: raise(ArgumentError, "'required_scopes' cannot be an empty list, remove it")

  def check!(other) do
    raise(ArgumentError, "'required_scopes' must be a list of strings, got: #{inspect(other)}")
  end

  @doc """
  The required scopes of an entity. A map or `nil` has none. The bind
  stage of the pipeline (OzMcp.Pipeline.Bind) copies them into the
  field `required_scopes` of the bound entity, where the scope stage and
  the list filters read them.
  """
  @spec required(term()) :: [String.t()]
  def required(%{__struct__: _, required_scopes: scopes}) when is_list(scopes), do: scopes
  def required(_entity), do: []

  @doc "True when the principal holds all the scopes."
  @spec granted?(Principal.t(), [String.t()]) :: boolean()
  def granted?(%Principal{} = principal, scopes), do: Principal.scope?(principal, scopes)

  @doc "True when the principal can use the entity (the entity needs no scope, or the principal holds them)."
  @spec visible?(term(), Principal.t()) :: boolean()
  def visible?(entity, %Principal{} = principal), do: granted?(principal, required(entity))

  @doc """
  The `scope` of a step-up challenge: the scopes that the principal
  holds, then the needed scopes that are not in the list. `needed` empty
  means the `challenge_scopes` of the server. A granted scope that is not
  an RFC 6749 scope token is dropped: it cannot go in the header.
  """
  @spec step_up(Principal.t(), [String.t()], [String.t()]) :: [String.t()]
  def step_up(%Principal{scopes: granted}, needed, challenge_scopes) do
    needed = if needed == [], do: challenge_scopes, else: needed

    granted
    |> Enum.filter(&OzMcp.Auth.scope_token?/1)
    |> Kernel.++(needed)
    |> Enum.uniq()
  end

  @kinds [:tools, :resources, :templates, :prompts]

  @doc """
  All the scopes that the modules of the server require, sorted. The
  function reads the catalog of the server, which holds the scopes of
  the entities of each kind. It never calls `list/0` of a module: the
  catalog was read one time, at the boot of the instance.
  """
  @spec declared(module()) :: [String.t()]
  def declared(server) do
    @kinds
    |> Enum.flat_map(&declared(server, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The scopes that the modules of one kind (`:tools`, `:resources`,
  `:templates` or `:prompts`) declare: the `required_scopes` of the
  entities of the kind, which the catalog holds. Sorted. Empty when the
  kind has no block, or when no entity of the kind needs a scope.
  """
  @spec declared(module(), atom()) :: [String.t()]
  def declared(server, kind) do
    config =
      if Code.ensure_loaded?(server) and function_exported?(server, :config, 0),
        do: server.config(),
        else: %{}

    case Map.get(config, kind) do
      %{modules: _modules} -> catalog_scopes(server, kind)
      _none -> []
    end
  end

  @doc """
  The `scopes_supported` of the metadata document: the list that the
  server sets, or else the scopes that the modules of the server
  require, or `nil` when there is neither.
  """
  @spec supported(module(), map()) :: [String.t()] | nil
  def supported(_server, %{scopes_supported: scopes}) when is_list(scopes), do: scopes

  def supported(server, _auth) do
    case declared(server) do
      [] -> nil
      scopes -> scopes
    end
  end

  defp catalog_scopes(server, kind) do
    server |> Catalog.fetch() |> Catalog.required_scopes(kind)
  end

  # An improper list is a wrong value, not a crash.
  #
  defp token_list?([]), do: true
  defp token_list?([scope | rest]), do: OzMcp.Auth.scope_token?(scope) and token_list?(rest)
  defp token_list?(_improper), do: false
end
