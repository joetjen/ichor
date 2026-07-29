defmodule Support.NoActions do
  @moduledoc "An Actions module implementing none of the optional callbacks, to exercise the default fallback."

  @behaviour Ichor.Actions
end
