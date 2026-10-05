## api.nim - Clean Host Interface, Macro Auto-Binder & Dynamic FFI

import compiler, vm
import std/macros
import std/dynlib
import std/[math, os, strutils]
export compiler.Value, compiler.ObjKind, compiler.isNum, compiler.isBool, compiler.isObjKind, compiler.asNum, compiler.asBool, compiler.asObjString, compiler.asObjUserData, compiler.valNil, compiler.valNum, compiler.valBool, compiler.valObj, vm.InterpretResult, vm.VM

proc runScript*(source: string): InterpretResult =
  var vm = initVM()
  result = vm.interpret(source)
  freeVM(vm)

proc runScriptEx*(source: string, vm: var VM): InterpretResult =
  return vm.interpret(source)

macro exposeProc*(vm: var VM, procSym: typed): untyped =
  ## Automatically generates a zero-overhead NativeFn bridge for any Nim proc
  var fnSym = procSym
  if fnSym.kind in {nnkClosedSymChoice, nnkOpenSymChoice}:
    var selected = fnSym[0]
    for choice in fnSym:
      let p = choice.getImpl()[3]
      if p.len > 1:
        let pType = p[1][^2]
        if eqIdent(pType, "string") or eqIdent(pType, "float") or eqIdent(pType, "float64") or eqIdent(pType, "int") or eqIdent(pType, "bool"):
          selected = choice
          break
    fnSym = selected

  let impl = fnSym.getImpl()
  let params = impl[3] # FormalParams AST

  let returnType = params[0]
  let wrapperName = ident("wrap_" & fnSym.strVal)
  let argsIdent = ident("args")
  let argcIdent = ident("argc")
  let vmPtrIdent = ident("vmPtr")

  var unpackList = newNimNode(nnkStmtList)
  var rawCall = newCall(fnSym)
  var argIdx = 0

  for i in 1 ..< params.len:
    let identDefs = params[i]
    let paramType = identDefs[^2]
    let hasDefault = identDefs[^1].kind != nnkEmpty

    if hasDefault: break

    for j in 0 .. identDefs.len - 3:
      let paramIdent = ident(identDefs[j].strVal)
      let idx = argIdx
      inc argIdx

      if eqIdent(paramType, "float64") or eqIdent(paramType, "float") or eqIdent(paramType, "float32"):
        unpackList.add quote do:
          if not isNum(`argsIdent`[`idx`]): return valNil()
          let `paramIdent` = asNum(`argsIdent`[`idx`])
      elif eqIdent(paramType, "int"):
        unpackList.add quote do:
          if not isNum(`argsIdent`[`idx`]): return valNil()
          let `paramIdent` = int(asNum(`argsIdent`[`idx`]))
      elif eqIdent(paramType, "string"):
        unpackList.add quote do:
          if not isObjKind(`argsIdent`[`idx`], objString): return valNil()
          let `paramIdent` = asObjString(`argsIdent`[`idx`]).strVal
      elif eqIdent(paramType, "bool"):
        unpackList.add quote do:
          if not isBool(`argsIdent`[`idx`]): return valNil()
          let `paramIdent` = asBool(`argsIdent`[`idx`])
      elif eqIdent(paramType, "char"):
        unpackList.add quote do:
          if not isObjKind(`argsIdent`[`idx`], objString) or asObjString(`argsIdent`[`idx`]).strVal.len == 0: return valNil()
          let `paramIdent` = asObjString(`argsIdent`[`idx`]).strVal[0]

      rawCall.add(paramIdent)

  let expectedCount = argIdx

  var returnStmt: NimNode
  if returnType.kind == nnkEmpty:
    returnStmt = quote do:
      `rawCall`
      return valNil()
  elif eqIdent(returnType, "float64") or eqIdent(returnType, "float") or eqIdent(returnType, "float32") or eqIdent(returnType, "int"):
    returnStmt = quote do:
      return valNum(float64(`rawCall`))
  elif eqIdent(returnType, "bool"):
    returnStmt = quote do:
      return valBool(`rawCall`)
  elif eqIdent(returnType, "string"):
    returnStmt = quote do:
      let resStr = `rawCall`
      return internStringImpl(`vmPtrIdent`, resStr)
  elif eqIdent(returnType, "char"):
    returnStmt = quote do:
      let resChar = `rawCall`
      return internStringImpl(`vmPtrIdent`, $resChar)

  var procBody = newNimNode(nnkStmtList)
  procBody.add quote do:
    if `argcIdent` < `expectedCount`:
      return valNil()
  procBody.add(unpackList)
  procBody.add(returnStmt)

  let procDef = quote do:
    let `wrapperName`: NativeFn = proc(`vmPtrIdent`: pointer, `argcIdent`: int, `argsIdent`: ptr UncheckedArray[Value]): Value {.nimcall.} =
      discard
    `vm`.registerNative(astToStr(`fnSym`), `wrapperName`)

  procDef[0][0][2][6] = procBody
  result = procDef

proc nativeFFILoad*(vmPtr: pointer, argc: int, args: ptr UncheckedArray[Value]): Value {.nimcall.} =
  let vm = cast[ptr VM](vmPtr)
  if argc < 1 or not isObjKind(args[0], objString):
    return valNil()

  let symName = asObjString(args[0]).strVal
  let handle = loadLib()
  if handle == nil:
    vm[].runtimeError("Could not open executable handle for FFI symbol lookup.")
    return valNil()

  let symAddr = handle.symAddr(symName.cstring)
  if symAddr == nil:
    vm[].runtimeError("Could not resolve FFI symbol: " & symName)
    return valNil()

  let udata = cast[ptr ObjUserData](alloc0(sizeof(ObjUserData)))
  udata.header = ObjHeader(kind: objUserData)
  udata.data = symAddr
  vm[].trackObject(cast[pointer](udata))
  return valObj(udata)

proc nativeFFICall*(vmPtr: pointer, argc: int, args: ptr UncheckedArray[Value]): Value {.nimcall.} =
  if argc < 1 or not isObjKind(args[0], objUserData):
    return valNil()

  let udata = asObjUserData(args[0])
  let fnPtr = udata.data
  if fnPtr == nil:
    return valNil()

  if argc == 1:
    type Fn0 = proc(): float64 {.cdecl.}
    let res = cast[Fn0](fnPtr)()
    return valNum(res)
  elif argc == 2:
    if isNum(args[1]):
      type Fn1F = proc(a: float64): float64 {.cdecl.}
      let res = cast[Fn1F](fnPtr)(asNum(args[1]))
      return valNum(res)
    elif isObjKind(args[1], objString):
      let strVal = asObjString(args[1]).strVal
      type Fn1S = proc(s: cstring): int32 {.cdecl.}
      let res = cast[Fn1S](fnPtr)(strVal.cstring)
      return valNum(float64(res))
  elif argc == 3:
    if isNum(args[1]) and isNum(args[2]):
      type Fn2F = proc(a, b: float64): float64 {.cdecl.}
      let res = cast[Fn2F](fnPtr)(asNum(args[1]), asNum(args[2]))
      return valNum(res)

  return valNil()

proc env*(key: string): string = getEnv(key)

proc loadStdlib*(vm: var VM) =
  # Math
  vm.exposeProc(sin)
  vm.exposeProc(cos)
  vm.exposeProc(sqrt)

  # OS & Environment
  vm.exposeProc(env)
  vm.exposeProc(fileExists)
  vm.exposeProc(dirExists)

  # String utilities
  vm.exposeProc(strip)
  vm.exposeProc(toUpperAscii)
  vm.exposeProc(toLowerAscii)

  # Dynamic Runtime FFI
  vm.registerNative("ffiLoad", nativeFFILoad)
  vm.registerNative("ffiCall", nativeFFICall)

proc callFunction*(vm: var VM, fnName: string, args: openArray[Value]): Value =
  let internedVal = internStringImpl(addr vm, fnName)
  let fnObj = asObjString(internedVal)
  var fnVal: Value
  if not tableGet(addr vm.globals, fnObj, fnVal):
    return valNil()

  vm.push(fnVal)
  for arg in args:
    vm.push(arg)

  if vm.callValue(fnVal, args.len):
    if vm.frameCount > 0:
      discard vm.run()
    return vm.pop()
  return valNil()
