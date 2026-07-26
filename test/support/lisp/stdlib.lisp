; Layer 2 of the three-layer bootstrap: built
; entirely from the 6 core forms plus Layer 1's primitives -- `if`/`let`
; need the grammar or the Elixir dispatcher to know nothing about them.

(defmacro if (test then else) (list 'cond test then 1 else))
(defmacro let (bindings body) (list (list 'fn (list (first bindings)) body) (second bindings)))
