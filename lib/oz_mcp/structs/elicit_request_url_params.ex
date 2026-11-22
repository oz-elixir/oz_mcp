defmodule OzMcp.Structs.ElicitRequestURLParams do
  @moduledoc """
  Helper module used to build the params of an `elicitation/create` request
  in URL mode: the user is sent to a web page, the data never passes
  through the client.

  _(MCP protocol: 2025-11-25)_

  `url` must be an absolute `http` or `https` URL without credentials
  (`https://user:pass@host/` is rejected: clients show the URL to the user). `elicitationId`
  identifies the interaction (the server sends
  `notifications/elicitation/complete` with it).

  ## Short example:

  ```elixir
  %ElicitRequestURLParams{}
    |> ElicitRequestURLParams.message("Authorize the access")
    |> ElicitRequestURLParams.url("https://example.com/authorize")
    |> ElicitRequestURLParams.elicitation_id("e-1")
    |> ElicitRequestURLParams.build()
  ```

  Result:

  ```elixir
  %{
    mode: "url",
    message: "Authorize the access",
    url: "https://example.com/authorize",
    elicitationId: "e-1"
  }
  ```

  Specification: [ElicitRequestURLParams](https://modelcontextprotocol.io/specification/2025-11-25/schema#elicitrequesturlparams)
  """

  use OzMcp.Structs.Wire,
    const: %{mode: "url"},
    fields: [
      message: {:string, required: true},
      url: {:string, required: true},
      elicitationId: {:string, required: true},
      _meta: :meta,
      task: {:struct, OzMcp.Structs.TaskMetadata}
    ]

  def build(struct) do
    result = super(struct)
    validate_url(struct.url)
    result
  end

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _ ->
        raise ArgumentError,
              "The 'url' field must be an absolute http or https URL without credentials, got: #{inspect(url)}"
    end
  end
end
