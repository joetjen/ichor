defmodule Grammar.IR.CharClass do
  @moduledoc """
  Character class, including unicode ranges: `[a-z0-9_]`.

  Each range is an inclusive pair of unicode codepoints; a single character
  is represented as `{cp, cp}`. Negated classes (`[^...]`) are a front-end
  concern -- they desugar to `NotPred` wrapping this node, followed by
  `Any`, before reaching the IR, so this node never carries a negation
  flag itself.
  """

  @type range :: {first :: non_neg_integer(), last :: non_neg_integer()}

  @type t :: %__MODULE__{ranges: [range()], meta: Grammar.IR.Meta.t()}

  defstruct ranges: [], meta: %Grammar.IR.Meta{}
end
