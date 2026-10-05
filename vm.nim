## vm.nim - High-Performance CallFrame & Stack VM for Nim Script Engine

import compiler
import std/tables
export tables

const
  FRAMES_MAX* = 64
  STACK_MAX* = FRAMES_MAX * 256

type
  InterpretResult* = enum
    irOk,
    irCompileError,
    irRuntimeError

  CallFrame* = object
    fn*: ptr ObjFunction
    ip*: int
    slots*: int # Offset into vm.stack for local variables of this frame

  VM* = object
    frames*: array[FRAMES_MAX, CallFrame]
    frameCount*: int
    stack*: array[STACK_MAX, Value]
    stackTop*: int
    globals*: Table[string, Value]
    strings*: Table[string, ptr ObjString] # Interned string table
    objects*: seq[pointer] # Allocated heap objects tracking
    output*: string

proc initVM*(): VM =
  result.frameCount = 0
  result.stackTop = 0
  result.globals = initTable[string, Value]()
  result.strings = initTable[string, ptr ObjString]()
  result.objects = @[]
  result.output = ""

proc resetStack*(vm: var VM) =
  vm.stackTop = 0
  vm.frameCount = 0

proc runtimeError*(vm: var VM, message: string) =
  stderr.write("Runtime Error: " & message & "\n")
  for i in countdown(vm.frameCount - 1, 0):
    let frame = addr vm.frames[i]
    let fn = frame.fn
    let line = if frame.ip - 1 < fn.chunk.lines.len and frame.ip - 1 >= 0: fn.chunk.lines[frame.ip - 1] else: 0
    stderr.write("[line " & $line & "] in ")
    if fn.name.len == 0:
      stderr.write("script\n")
    else:
      stderr.write(fn.name & "()\n")
  vm.resetStack()

proc push*(vm: var VM, value: Value) =
  if vm.stackTop >= STACK_MAX:
    vm.runtimeError("Stack overflow")
    return
  vm.stack[vm.stackTop] = value
  inc vm.stackTop

proc pop*(vm: var VM): Value =
  if vm.stackTop <= 0:
    vm.runtimeError("Stack underflow")
    return valNil()
  dec vm.stackTop
  return vm.stack[vm.stackTop]

proc peek*(vm: var VM, distance: int = 0): Value =
  if vm.stackTop - 1 - distance < 0:
    return valNil()
  return vm.stack[vm.stackTop - 1 - distance]

proc isTruthy*(value: Value): bool =
  if isNil(value): return false
  if isBool(value): return asBool(value)
  if isNum(value): return asNum(value) != 0.0
  if isObjKind(value, objString): return asObjString(value).strVal.len > 0
  return true

proc internString*(vm: var VM, str: string): ptr ObjString =
  if vm.strings.contains(str):
    return vm.strings[str]
  let obj = newObjString(str)
  vm.strings[str] = obj
  vm.objects.add(cast[pointer](obj))
  return obj

proc registerNative*(vm: var VM, name: string, nativeProc: NativeFn) =
  let nativeObj = cast[ptr ObjNative](alloc0(sizeof(ObjNative)))
  nativeObj.header = ObjHeader(kind: objNative)
  nativeObj.name = name
  nativeObj.fn = nativeProc
  vm.objects.add(cast[pointer](nativeObj))
  let internedName = vm.internString(name)
  vm.globals[internedName.strVal] = valObj(nativeObj)

proc freeVM*(vm: var VM) =
  for objPtr in vm.objects:
    if objPtr != nil:
      let header = cast[ptr ObjHeader](objPtr)
      case header.kind
      of objString:
        let sObj = cast[ptr ObjString](objPtr)
        sObj.strVal = ""
        dealloc(sObj)
      of objFunction:
        let fObj = cast[ptr ObjFunction](objPtr)
        fObj.name = ""
        fObj.chunk.code = @[]
        fObj.chunk.constants = @[]
        fObj.chunk.lines = @[]
        dealloc(fObj)
      of objNative:
        let nObj = cast[ptr ObjNative](objPtr)
        nObj.name = ""
        dealloc(nObj)
      of objUserData:
        let uObj = cast[ptr ObjUserData](objPtr)
        if uObj.finalizer != nil and uObj.data != nil:
          uObj.finalizer(uObj.data)
        dealloc(uObj)
  vm.objects.setLen(0)
  vm.strings.clear()
  vm.globals.clear()
  vm.resetStack()

proc call*(vm: var VM, fn: ptr ObjFunction, argCount: int): bool =
  if argCount != fn.arity:
    vm.runtimeError("Expected " & $fn.arity & " arguments but got " & $argCount & ".")
    return false

  if vm.frameCount == FRAMES_MAX:
    vm.runtimeError("Call frame overflow.")
    return false

  var frame = addr vm.frames[vm.frameCount]
  inc vm.frameCount
  frame.fn = fn
  frame.ip = 0
  frame.slots = vm.stackTop - argCount - 1
  return true

proc callValue*(vm: var VM, callee: Value, argCount: int): bool =
  if isObj(callee):
    case cast[ptr ObjHeader](asObj(callee)).kind
    of objFunction:
      return vm.call(asObjFunction(callee), argCount)
    of objNative:
      let nativeFn = asObjNative(callee)
      let argsPtr = cast[ptr UncheckedArray[Value]](addr vm.stack[vm.stackTop - argCount])
      let resVal = nativeFn.fn(addr vm, argCount, argsPtr)
      vm.stackTop -= argCount + 1
      vm.push(resVal)
      return true
    else: discard

  vm.runtimeError("Can only call functions and classes.")
  return false

proc readByte*(frame: ptr CallFrame): uint8 =
  result = frame.fn.chunk.code[frame.ip]
  inc frame.ip

proc readShort*(frame: ptr CallFrame): uint16 =
  let high = uint16(frame.fn.chunk.code[frame.ip]) shl 8
  let low = uint16(frame.fn.chunk.code[frame.ip + 1])
  frame.ip += 2
  return high or low

proc readConstant*(frame: ptr CallFrame): Value =
  let index = frame.readByte()
  return frame.fn.chunk.constants[int(index)]

proc readString*(frame: ptr CallFrame): ptr ObjString =
  return asObjString(frame.readConstant())

proc run*(vm: var VM): InterpretResult =
  var frame = addr vm.frames[vm.frameCount - 1]

  while true:
    let instruction = OpCode(frame.readByte())
    case instruction
    of opConstant:
      let constant = frame.readConstant()
      vm.push(constant)

    of opNil:
      vm.push(valNil())

    of opTrue:
      vm.push(valBool(true))

    of opFalse:
      vm.push(valBool(false))

    of opPop:
      discard vm.pop()

    of opGetLocal:
      let slot = frame.readByte()
      vm.push(vm.stack[frame.slots + int(slot)])

    of opSetLocal:
      let slot = frame.readByte()
      vm.stack[frame.slots + int(slot)] = vm.peek(0)

    of opDefineGlobal:
      let nameStr = frame.readString().strVal
      vm.globals[nameStr] = vm.pop()

    of opGetGlobal:
      let nameStr = frame.readString().strVal
      if not vm.globals.contains(nameStr):
        vm.runtimeError("Undefined variable '" & nameStr & "'.")
        return irRuntimeError
      vm.push(vm.globals[nameStr])

    of opSetGlobal:
      let nameStr = frame.readString().strVal
      if not vm.globals.contains(nameStr):
        vm.runtimeError("Undefined variable '" & nameStr & "'.")
        return irRuntimeError
      vm.globals[nameStr] = vm.peek(0)

    of opEqual:
      let b = vm.pop()
      let a = vm.pop()
      vm.push(valBool(valuesEqual(a, b)))

    of opGreater:
      let b = vm.pop()
      let a = vm.pop()
      if isNum(a) and isNum(b):
        vm.push(valBool(asNum(a) > asNum(b)))
      elif isObjKind(a, objString) and isObjKind(b, objString):
        vm.push(valBool(asObjString(a).strVal > asObjString(b).strVal))
      else:
        vm.runtimeError("Operands must be two numbers or two strings.")
        return irRuntimeError

    of opLess:
      let b = vm.pop()
      let a = vm.pop()
      if isNum(a) and isNum(b):
        vm.push(valBool(asNum(a) < asNum(b)))
      elif isObjKind(a, objString) and isObjKind(b, objString):
        vm.push(valBool(asObjString(a).strVal < asObjString(b).strVal))
      else:
        vm.runtimeError("Operands must be two numbers or two strings.")
        return irRuntimeError

    of opAdd:
      let b = vm.pop()
      let a = vm.pop()
      if isNum(a) and isNum(b):
        vm.push(valNum(asNum(a) + asNum(b)))
      elif isObjKind(a, objString) and isObjKind(b, objString):
        let concatStr = asObjString(a).strVal & asObjString(b).strVal
        let strObj = vm.internString(concatStr)
        vm.push(valObj(strObj))
      else:
        vm.runtimeError("Operands must be numbers or strings.")
        return irRuntimeError

    of opSubtract:
      let b = vm.pop()
      let a = vm.pop()
      if not isNum(a) or not isNum(b):
        vm.runtimeError("Operands must be numbers.")
        return irRuntimeError
      vm.push(valNum(asNum(a) - asNum(b)))

    of opMultiply:
      let b = vm.pop()
      let a = vm.pop()
      if not isNum(a) or not isNum(b):
        vm.runtimeError("Operands must be numbers.")
        return irRuntimeError
      vm.push(valNum(asNum(a) * asNum(b)))

    of opDivide:
      let b = vm.pop()
      let a = vm.pop()
      if not isNum(a) or not isNum(b):
        vm.runtimeError("Operands must be numbers.")
        return irRuntimeError
      if asNum(b) == 0.0:
        vm.runtimeError("Division by zero.")
        return irRuntimeError
      vm.push(valNum(asNum(a) / asNum(b)))

    of opNot:
      let val = vm.pop()
      vm.push(valBool(not isTruthy(val)))

    of opNegate:
      let val = vm.pop()
      if not isNum(val):
        vm.runtimeError("Operand must be a number.")
        return irRuntimeError
      vm.push(valNum(-asNum(val)))

    of opPrint:
      let val = vm.pop()
      let strOutput = $val
      echo strOutput
      vm.output.add(strOutput & "\n")

    of opJumpIfFalse:
      let offset = int(frame.readShort())
      if not isTruthy(vm.peek(0)):
        frame.ip += offset

    of opJump:
      let offset = int(frame.readShort())
      frame.ip += offset

    of opLoop:
      let offset = int(frame.readShort())
      frame.ip -= offset

    of opCall:
      let argCount = int(frame.readByte())
      if not vm.callValue(vm.peek(argCount), argCount):
        return irRuntimeError
      frame = addr vm.frames[vm.frameCount - 1]

    of opReturn:
      let resVal = vm.pop()
      dec vm.frameCount
      if vm.frameCount == 0:
        vm.stackTop = frame.slots
        vm.push(resVal)
        return irOk

      vm.stackTop = frame.slots
      vm.push(resVal)
      frame = addr vm.frames[vm.frameCount - 1]

proc interpret*(vm: var VM, source: string): InterpretResult =
  let scriptFn = compile(source)
  if scriptFn == nil:
    return irCompileError

  vm.push(valObj(scriptFn))
  discard vm.call(scriptFn, 0)
  return vm.run()
