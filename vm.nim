## vm.nim - Stack-based Bytecode Virtual Machine for lightweight Nim script engine

import compiler
import std/tables
export tables

type
  InterpretResult* = enum
    irOk,
    irCompileError,
    irRuntimeError

  VM* = object
    chunk*: Chunk
    ip*: int
    stack*: seq[Value]
    globals*: Table[string, Value]
    output*: string # Stream/capture output for tests if needed

proc initVM*(): VM =
  VM(
    chunk: Chunk(),
    ip: 0,
    stack: @[],
    globals: initTable[string, Value](),
    output: ""
  )

proc resetStack*(vm: var VM) =
  vm.stack.setLen(0)

proc runtimeError*(vm: var VM, message: string) =
  let line = if vm.ip - 1 < vm.chunk.lines.len and vm.ip - 1 >= 0: vm.chunk.lines[vm.ip - 1] else: 0
  stderr.write("[line " & $line & "] Runtime Error: " & message & "\n")
  vm.resetStack()

proc push*(vm: var VM, value: Value) =
  vm.stack.add(value)

proc pop*(vm: var VM): Value =
  if vm.stack.len == 0:
    vm.runtimeError("Stack underflow")
    return Value(kind: vkNil)
  return vm.stack.pop()

proc peek*(vm: var VM, distance: int = 0): Value =
  if vm.stack.len - 1 - distance < 0:
    return Value(kind: vkNil)
  return vm.stack[vm.stack.len - 1 - distance]

proc isTruthy*(value: Value): bool =
  case value.kind
  of vkNil: false
  of vkBool: value.boolVal
  of vkNumber: value.numberVal != 0.0
  of vkString: value.strVal.len > 0

proc readByte*(vm: var VM): uint8 =
  result = vm.chunk.code[vm.ip]
  inc vm.ip

proc readShort*(vm: var VM): uint16 =
  let high = uint16(vm.chunk.code[vm.ip]) shl 8
  let low = uint16(vm.chunk.code[vm.ip + 1])
  vm.ip += 2
  return high or low

proc readConstant*(vm: var VM): Value =
  let index = vm.readByte()
  return vm.chunk.constants[int(index)]

proc run*(vm: var VM): InterpretResult =
  while vm.ip < vm.chunk.code.len:
    let instruction = OpCode(vm.readByte())
    case instruction
    of opConstant:
      let constant = vm.readConstant()
      vm.push(constant)

    of opNil:
      vm.push(Value(kind: vkNil))

    of opTrue:
      vm.push(Value(kind: vkBool, boolVal: true))

    of opFalse:
      vm.push(Value(kind: vkBool, boolVal: false))

    of opPop:
      discard vm.pop()

    of opDefineGlobal:
      let nameValue = vm.readConstant()
      if nameValue.kind != vkString:
        vm.runtimeError("Global variable name must be a string")
        return irRuntimeError
      vm.globals[nameValue.strVal] = vm.pop()

    of opGetGlobal:
      let nameValue = vm.readConstant()
      if nameValue.kind != vkString:
        vm.runtimeError("Global variable name must be a string")
        return irRuntimeError
      if not vm.globals.contains(nameValue.strVal):
        vm.runtimeError("Undefined variable '" & nameValue.strVal & "'.")
        return irRuntimeError
      vm.push(vm.globals[nameValue.strVal])

    of opSetGlobal:
      let nameValue = vm.readConstant()
      if nameValue.kind != vkString:
        vm.runtimeError("Global variable name must be a string")
        return irRuntimeError
      if not vm.globals.contains(nameValue.strVal):
        vm.runtimeError("Undefined variable '" & nameValue.strVal & "'.")
        return irRuntimeError
      # Assignment evaluates expression on stack and assigns to global variable without popping
      vm.globals[nameValue.strVal] = vm.peek(0)

    of opEqual:
      let b = vm.pop()
      let a = vm.pop()
      vm.push(Value(kind: vkBool, boolVal: valuesEqual(a, b)))

    of opGreater:
      let b = vm.pop()
      let a = vm.pop()
      if a.kind == vkNumber and b.kind == vkNumber:
        vm.push(Value(kind: vkBool, boolVal: a.numberVal > b.numberVal))
      elif a.kind == vkString and b.kind == vkString:
        vm.push(Value(kind: vkBool, boolVal: a.strVal > b.strVal))
      else:
        vm.runtimeError("Operands must be two numbers or two strings.")
        return irRuntimeError

    of opLess:
      let b = vm.pop()
      let a = vm.pop()
      if a.kind == vkNumber and b.kind == vkNumber:
        vm.push(Value(kind: vkBool, boolVal: a.numberVal < b.numberVal))
      elif a.kind == vkString and b.kind == vkString:
        vm.push(Value(kind: vkBool, boolVal: a.strVal < b.strVal))
      else:
        vm.runtimeError("Operands must be two numbers or two strings.")
        return irRuntimeError

    of opAdd:
      let b = vm.pop()
      let a = vm.pop()
      if a.kind == vkNumber and b.kind == vkNumber:
        vm.push(Value(kind: vkNumber, numberVal: a.numberVal + b.numberVal))
      elif a.kind == vkString and b.kind == vkString:
        vm.push(Value(kind: vkString, strVal: a.strVal & b.strVal))
      elif a.kind == vkString or b.kind == vkString:
        vm.push(Value(kind: vkString, strVal: $a & $b))
      else:
        vm.runtimeError("Operands must be numbers or strings.")
        return irRuntimeError

    of opSubtract:
      let b = vm.pop()
      let a = vm.pop()
      if a.kind != vkNumber or b.kind != vkNumber:
        vm.runtimeError("Operands must be numbers.")
        return irRuntimeError
      vm.push(Value(kind: vkNumber, numberVal: a.numberVal - b.numberVal))

    of opMultiply:
      let b = vm.pop()
      let a = vm.pop()
      if a.kind != vkNumber or b.kind != vkNumber:
        vm.runtimeError("Operands must be numbers.")
        return irRuntimeError
      vm.push(Value(kind: vkNumber, numberVal: a.numberVal * b.numberVal))

    of opDivide:
      let b = vm.pop()
      let a = vm.pop()
      if a.kind != vkNumber or b.kind != vkNumber:
        vm.runtimeError("Operands must be numbers.")
        return irRuntimeError
      if b.numberVal == 0.0:
        vm.runtimeError("Division by zero.")
        return irRuntimeError
      vm.push(Value(kind: vkNumber, numberVal: a.numberVal / b.numberVal))

    of opNot:
      let val = vm.pop()
      vm.push(Value(kind: vkBool, boolVal: not isTruthy(val)))

    of opNegate:
      let val = vm.pop()
      if val.kind != vkNumber:
        vm.runtimeError("Operand must be a number.")
        return irRuntimeError
      vm.push(Value(kind: vkNumber, numberVal: -val.numberVal))

    of opPrint:
      let val = vm.pop()
      let strOutput = $val
      echo strOutput
      vm.output.add(strOutput & "\n")

    of opJumpIfFalse:
      let offset = int(vm.readShort())
      if not isTruthy(vm.peek(0)):
        vm.ip += offset

    of opJump:
      let offset = int(vm.readShort())
      vm.ip += offset

    of opLoop:
      let offset = int(vm.readShort())
      vm.ip -= offset

    of opReturn:
      return irOk

  return irOk

proc interpret*(vm: var VM, source: string): InterpretResult =
  var chunk = Chunk()
  if not compile(source, chunk):
    return irCompileError
  vm.chunk = chunk
  vm.ip = 0
  return vm.run()
