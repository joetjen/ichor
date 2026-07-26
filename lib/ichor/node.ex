defmodule Ichor.Node do
  @moduledoc """
  The default-fallback shape `Ichor.Actions` builds for a matched rule
  that has more than one meaningful capture (a rule with exactly one
  capture passes that capture's own value straight through instead):
  `rule` names the matched rule, `captures` maps each capture name to its
  already-evaluated value (or a list of values, for a name captured more
  than once -- e.g. inside a `*`), and `span` locates the whole match
  back in the original input.
  """

  @type t :: %__MODULE__{
          rule: atom(),
          captures: %{optional(atom()) => term() | [term()]},
          span: Grammar.IR.Meta.source_span() | nil
        }

  defstruct [:rule, :captures, :span]
end
