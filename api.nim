## api.nim - Clean Host Interface & Native Nim Bridge

import compiler, vm
import std/math
export compiler.Value, vm.InterpretResult, vm.VM

proc runScript*(source: string): InterpretResult =
  var vm = initVM()
  return vm.interpret(source)

proc runScriptEx*(source: string, vm: var VM): InterpretResult =
  return vm.interpret(source)

# Native Math Bridge Procs
proc nativeSin*(vm: pointer, argc: int, args: ptr UncheckedArray[Value]): Value {.nimcall.} =
  if argc < 1 or not isNum(args[0]):
    return valNil()
  return valNum(sin(asNum(args[0])))

proc nativeCos*(vm: pointer, argc: int, args: ptr UncheckedArray[Value]): Value {.nimcall.} =
  if argc < 1 or not isNum(args[0]):
    return valNil()
  return valNum(cos(asNum(args[0])))

proc nativeSqrt*(vm: pointer, argc: int, args: ptr UncheckedArray[Value]): Value {.nimcall.} =
  if argc < 1 or not isNum(args[0]):
    return valNil()
  return valNum(sqrt(asNum(args[0])))

proc nativeAbs*(vm: pointer, argc: int, args: ptr UncheckedArray[Value]): Value {.nimcall.} =
  if argc < 1 or not isNum(args[0]):
    return valNil()
  return valNum(abs(asNum(args[0])))

proc registerMathModule*(vm: var VM) =
  vm.registerNative("sin", nativeSin)
  vm.registerNative("cos", nativeCos)
  vm.registerNative("sqrt", nativeSqrt)
  vm.registerNative("abs", nativeAbs)

proc callFunction*(vm: var VM, fnName: string, args: openArray[Value]): Value =
  if not vm.globals.contains(fnName):
    return valNil()

  let fnVal = vm.globals[fnName]
  vm.push(fnVal)
  for arg in args:
    vm.push(arg)

  if vm.callValue(fnVal, args.len):
    discard vm.run()
    return vm.pop()
  return valNil()
