defmodule Native.InterpLR do
  @moduledoc "Native-backend wiring for the @engine lr CustomLexeme-dependency fixture -- compiled via Grammar.Native.LR."

  use Ichor,
    grammar: "../interp/interp_lr.aether",
    actions: InterpTest.Actions
end

defmodule Native.InterpGLR do
  @moduledoc "Native-backend wiring for the @engine glr CustomLexeme-dependency fixture -- compiled via Grammar.Native.GLR."

  use Ichor,
    grammar: "../interp/interp_glr.aether",
    actions: InterpTest.Actions
end
