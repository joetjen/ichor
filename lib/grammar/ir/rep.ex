defmodule Grammar.IR.Rep do
  @moduledoc """
  Bounded repetition: `expr{n}`, `expr{n,}`, `expr{n,m}`.

  `expr{n}` normalizes to `min: n, max: n`; the open-ended `expr{n,}` form
  normalizes to `max: :infinity`.
  """

  @type t :: %__MODULE__{
          expr: Grammar.IR.expr(),
          min: non_neg_integer(),
          max: non_neg_integer() | :infinity,
          meta: Grammar.IR.Meta.t()
        }

  defstruct [:expr, :min, :max, meta: %Grammar.IR.Meta{}]
end
