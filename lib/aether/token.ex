defmodule Aether.Token do
  @moduledoc """
  A single lexical token produced by `Aether.Lexer` from `.aether` source
  text.

  This is Ichor's own front-end scanning a grammar-description file, not to
  be confused with the "tokens" a *user's* Aether grammar itself declares
  (`ALL_UPPERCASE` productions) -- those become
  `Aether.Token{type: :upper_ident}` values here, same as any other
  identifier.
  """

  @type case_flag :: :default | :insensitive | :sensitive

  @type string_value :: %{text: String.t(), case: case_flag()}

  @type class_item ::
          {:range, first :: non_neg_integer(), last :: non_neg_integer()}
          | {:char, non_neg_integer()}
          | {:posix, :alpha | :alnum | :digit | :space | :hex}

  @type char_class_value :: %{negate: boolean(), items: [class_item()]}

  @type type ::
          :at_grammar
          | :at_root
          | :at_skip
          | :at_noskip
          | :at_case_insensitive
          | :at_indent
          | :at_samecol
          | :define
          | :pipe
          | :star
          | :plus
          | :question
          | :lbrace
          | :rbrace
          | :comma
          | :amp
          | :bang
          | :colon
          | :lparen
          | :rparen
          | :tilde
          | :dot
          | :upper_ident
          | :lower_ident
          | :string
          | :char_class
          | :regex
          | :number
          | :eof

  @type value :: String.t() | integer() | string_value() | char_class_value() | nil

  @type t :: %__MODULE__{
          type: type(),
          value: value(),
          line: pos_integer(),
          column: pos_integer()
        }

  defstruct [:type, :value, :line, :column]
end
