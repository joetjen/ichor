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

  @typedoc "Mirrors `Grammar.IR.Meta.source_span/0` (dev-only, in `ichor` proper): 1-based line, 1-based column, match length."
  @type source_span ::
          {line :: pos_integer(), column :: pos_integer(), length :: non_neg_integer()}

  @type t :: %__MODULE__{
          rule: atom(),
          captures: %{optional(atom()) => term() | [term()]},
          span: source_span() | nil
        }

  defstruct [:rule, :captures, :span]
end
