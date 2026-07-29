defmodule Native.PegGap do
  @moduledoc "Native-backend wiring for the @engine glr peg_gap fixture -- compiled via Grammar.Native.GLR."

  use Ichor,
    grammar: "../peg_gap/peg_gap_glr.aether",
    actions: PegGapTest.Actions
end

defmodule Native.AmbigTiebreak do
  @moduledoc "Native-backend wiring for the @engine glr ambig_tiebreak fixture -- compiled via Grammar.Native.GLR."

  use Ichor,
    grammar: "../ambig_tiebreak/ambig_tiebreak.aether",
    actions: AmbigTiebreakTest.Actions
end

defmodule Native.DanglingElse do
  @moduledoc "Native-backend wiring for the @engine glr dangling_else fixture -- compiled via Grammar.Native.GLR."

  use Ichor,
    grammar: "../dangling_else/dangling_else.aether",
    actions: DanglingElseTest.Actions
end
