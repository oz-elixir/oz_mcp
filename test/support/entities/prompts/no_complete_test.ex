# A prompt module with no `complete/4`: a server that declares the
# completions capability does not count it as a completer.
#

defmodule Support.Entities.Prompts.NoCompleteTest do
  use OzMcp.Config.Prompt, dsl?: false

  alias OzMcp.Structs.Prompt
  alias OzMcp.Utils.Error

  @prompts [%Prompt{} |> Prompt.name("no_complete")]

  def list do
    @prompts
  end

  def get(_ctx, _params), do: {:error, Error.new(-32601, "prompt not found")}
end
