defmodule Grammar.IR.Literal do
  @moduledoc """
  Exact string match.

  Case-insensitivity (`"lit"i`/`@case_insensitive`) and other literal-level
  sugar are a front-end concern -- they desugar to this node, or to a
  `Grammar.IR.CharClass`-based expansion, before reaching the IR. The IR
  node itself only ever means "match this exact byte sequence."
  """

  @type t :: %__MODULE__{value: binary(), meta: Grammar.IR.Meta.t()}

  defstruct value: "", meta: %Grammar.IR.Meta{}
end
