#
# Server of the end-to-end suite for the URI template operators: the
# template module of the operators and the `completions` capability, so
# a completion can name a template string as its ref uri.
#
defmodule Support.Servers.Rfc6570 do
  use OzMcp.Config.Server

  server_info do
    name "rfc6570"
    version "1.0.0"
  end

  templates do
    template Support.Entities.Templates.Rfc6570Test
  end

  resources do
    resource Support.Entities.Resources.FirstTest
  end

  capabilities do
    resources do
    end

    completions %{}
  end
end
