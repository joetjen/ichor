# Phase 8's own done-when (design doc section 6): "calculator via the
# native backend matches VM output and is measurably faster." Run with:
#
#   MIX_ENV=test mix run bench/native_vs_vm.exs
#
# (MIX_ENV=test because Calculator.Actions/Native.Calculator/
# Support.ExampleGrammars live under test/support, only compiled in
# that environment -- see mix.exs's elixirc_paths/1.)

alias Support.ExampleGrammars

{:ok, vm_grammar} = Aether.Parser.parse(Map.fetch!(ExampleGrammars.all(), "4.1 calculator"))
{:ok, vm_grammar} = Grammar.Analysis.run(vm_grammar)

inputs = [
  "2 + 3 * 4",
  "(2 + 3) * 4",
  "1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10",
  "((1 + 2) * (3 + 4)) / (5 - 3) + 6 * 7 - 8 / 2 + 9"
]

# Sanity check first: this benchmark is meaningless if the two backends
# don't agree on the answer.
for input <- inputs do
  vm = Grammar.VM.run(vm_grammar, input, Calculator.Actions)
  native = Native.Calculator.run(input)

  if vm != native do
    raise "backends disagree on #{inspect(input)}: vm=#{inspect(vm)} native=#{inspect(native)}"
  end
end

iterations = 20_000

time = fn fun ->
  {micros, _} = :timer.tc(fn -> for _ <- 1..iterations, do: Enum.each(inputs, fun) end)
  micros
end

vm_micros = time.(fn input -> Grammar.VM.run(vm_grammar, input, Calculator.Actions) end)
native_micros = time.(fn input -> Native.Calculator.run(input) end)

IO.puts("#{iterations} iterations over #{length(inputs)} inputs each:")
IO.puts("  VM:     #{vm_micros / 1000} ms")
IO.puts("  Native: #{native_micros / 1000} ms")
IO.puts("  Native is #{Float.round(vm_micros / native_micros, 2)}x the VM's speed")
