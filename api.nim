## api.nim - Clean host interface for Nim applications

import compiler, vm
export compiler.Value, compiler.ValueKind, vm.InterpretResult, vm.VM

proc runScript*(source: string): InterpretResult =
  var vm = initVM()
  return vm.interpret(source)

proc runScriptEx*(source: string, vm: var VM): InterpretResult =
  return vm.interpret(source)
