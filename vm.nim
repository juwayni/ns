## vm.nim - High-Performance CallFrame, FlatTable & Mark-Sweep VM

import compiler

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

  Entry* = object
    key*: ptr ObjString
    val*: Value

  FlatTable* = object
    count*: int
    capacityMask*: int
    entries*: ptr UncheckedArray[Entry]

  VM* = object
    frames*: array[FRAMES_MAX, CallFrame]
    frameCount*: int
    stack*: array[STACK_MAX, Value]
    stackTop*: int
    globals*: FlatTable
    strings*: FlatTable
    objects*: pointer # Head pointer for linked list of heap objects
    grayStack*: seq[pointer]
    bytesAllocated*: int
    nextGC*: int
    isCompiling*: bool
    output*: string

proc initVM*(): VM =
  result.frameCount = 0
  result.stackTop = 0
  result.globals = FlatTable()
  result.strings = FlatTable()
  result.objects = nil
  result.grayStack = @[]
  result.bytesAllocated = 0
  result.nextGC = 1024 * 1024
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

# FlatTable Operations
proc findEntry*(entries: ptr UncheckedArray[Entry], capacityMask: int, key: ptr ObjString): ptr Entry =
  var index = int(key.hash) and capacityMask
  var tombstone: ptr Entry = nil
  for _ in 0 .. capacityMask:
    let entry = addr entries[index]
    if entry.key == nil:
      if isNil(entry.val):
        return if tombstone != nil: tombstone else: entry
      else:
        if tombstone == nil: tombstone = entry
    elif entry.key == key or (entry.key.hash == key.hash and entry.key.strVal == key.strVal):
      return entry
    index = (index + 1) and capacityMask
  return if tombstone != nil: tombstone else: addr entries[0]

proc tableGet*(table: ptr FlatTable, key: ptr ObjString, value: var Value): bool =
  if table == nil or table.entries == nil or table.count == 0: return false
  let entry = findEntry(table.entries, table.capacityMask, key)
  if entry.key == nil: return false
  value = entry.val
  return true

proc tableSet*(table: var FlatTable, key: ptr ObjString, value: Value): bool =
  if table.entries == nil or table.count + 1 > (table.capacityMask + 1) * 3 div 4:
    let newCapacity = if table.capacityMask == 0: 8 else: (table.capacityMask + 1) * 2
    let newMask = newCapacity - 1
    let newEntries = cast[ptr UncheckedArray[Entry]](alloc0(sizeof(Entry) * newCapacity))

    table.count = 0
    if table.entries != nil:
      for i in 0 .. table.capacityMask:
        let src = addr table.entries[i]
        if src.key != nil:
          let dest = findEntry(newEntries, newMask, src.key)
          dest.key = src.key
          dest.val = src.val
          inc table.count
      dealloc(table.entries)

    table.entries = newEntries
    table.capacityMask = newMask

  let entry = findEntry(table.entries, table.capacityMask, key)
  let isNewKey = entry.key == nil
  if isNewKey: inc table.count

  entry.key = key
  entry.val = value
  return isNewKey

# Mark-Sweep GC
proc markObject*(vm: var VM, objPtr: pointer) =
  if objPtr == nil: return
  let header = cast[ptr ObjHeader](objPtr)
  if header.isMarked: return
  header.isMarked = true
  vm.grayStack.add(objPtr)

proc markValue*(vm: var VM, value: Value) =
  if isObj(value):
    vm.markObject(asObj(value))

proc blackenObject*(vm: var VM, objPtr: pointer) =
  let header = cast[ptr ObjHeader](objPtr)
  case header.kind
  of objString, objNative, objUserData: discard
  of objFunction:
    let fn = cast[ptr ObjFunction](objPtr)
    for constVal in fn.chunk.constants:
      vm.markValue(constVal)

proc collectGarbage*(vm: var VM) =
  # Mark Roots
  for i in 0 ..< vm.stackTop:
    vm.markValue(vm.stack[i])

  for i in 0 ..< vm.frameCount:
    vm.markObject(cast[pointer](vm.frames[i].fn))

  if vm.globals.entries != nil:
    for i in 0 .. vm.globals.capacityMask:
      let entry = addr vm.globals.entries[i]
      if entry.key != nil:
        vm.markObject(cast[pointer](entry.key))
        vm.markValue(entry.val)

  # Process Gray Stack
  while vm.grayStack.len > 0:
    let obj = vm.grayStack.pop()
    vm.blackenObject(obj)

  # Sweep Strings Table
  if vm.strings.entries != nil:
    for i in 0 .. vm.strings.capacityMask:
      let entry = addr vm.strings.entries[i]
      if entry.key != nil and not entry.key.header.isMarked:
        entry.key = nil
        entry.val = valBool(true) # Tombstone marker to preserve probe chain

  # Sweep Objects Linked List
  var previous: pointer = nil
  var current = vm.objects

  while current != nil:
    let header = cast[ptr ObjHeader](current)
    let nextObj = header.next
    if header.isMarked:
      header.isMarked = false # Reset mark for next GC
      previous = current
      current = nextObj
    else:
      let unreached = current
      if previous != nil:
        cast[ptr ObjHeader](previous).next = nextObj
      else:
        vm.objects = nextObj

      current = nextObj
      case header.kind
      of objString:
        let sObj = cast[ptr ObjString](unreached)
        sObj.strVal = ""
        dealloc(sObj)
      of objFunction:
        let fObj = cast[ptr ObjFunction](unreached)
        fObj.name = ""
        fObj.chunk.code = @[]
        fObj.chunk.constants = @[]
        fObj.chunk.lines = @[]
        dealloc(fObj)
      of objNative:
        let nObj = cast[ptr ObjNative](unreached)
        nObj.name = ""
        dealloc(nObj)
      of objUserData:
        let uObj = cast[ptr ObjUserData](unreached)
        if uObj.finalizer != nil and uObj.data != nil:
          uObj.finalizer(uObj.data)
        dealloc(uObj)

  vm.nextGC = max(vm.bytesAllocated * 2, 1024 * 1024)

proc trackObject*(vm: var VM, objPtr: pointer) =
  let header = cast[ptr ObjHeader](objPtr)
  header.next = vm.objects
  vm.objects = objPtr
  vm.bytesAllocated += sizeof(ObjHeader) + 32
  if not vm.isCompiling and vm.bytesAllocated > vm.nextGC:
    vm.collectGarbage()

proc newFunctionImpl*(vmPtr: pointer, name: string = ""): ptr ObjFunction {.nimcall.} =
  let vm = cast[ptr VM](vmPtr)
  let fn = cast[ptr ObjFunction](alloc0(sizeof(ObjFunction)))
  fn.header = ObjHeader(kind: objFunction)
  fn.arity = 0
  fn.name = name
  fn.chunk = Chunk(code: @[], constants: @[], lines: @[])
  vm[].trackObject(cast[pointer](fn))
  return fn

proc internStringImpl*(vmPtr: pointer, str: string): Value {.nimcall.} =
  let vm = cast[ptr VM](vmPtr)
  var hash = 2166136261'u32
  for c in str:
    hash = hash xor uint8(c)
    hash = hash * 16777619'u32

  var tempObj = ObjString(header: ObjHeader(kind: objString), strVal: str, hash: hash)
  if vm.strings.entries != nil:
    let entry = findEntry(vm.strings.entries, vm.strings.capacityMask, addr tempObj)
    if entry.key != nil:
      return valObj(entry.key)

  let obj = cast[ptr ObjString](alloc0(sizeof(ObjString)))
  obj.header = ObjHeader(kind: objString)
  obj.strVal = str
  obj.hash = hash
  discard vm[].strings.tableSet(obj, valNil())
  vm[].trackObject(cast[pointer](obj))
  return valObj(obj)

proc registerNative*(vm: var VM, name: string, nativeProc: NativeFn) =
  let nativeObj = cast[ptr ObjNative](alloc0(sizeof(ObjNative)))
  nativeObj.header = ObjHeader(kind: objNative)
  nativeObj.name = name
  nativeObj.fn = nativeProc
  vm.trackObject(cast[pointer](nativeObj))
  let internedVal = internStringImpl(addr vm, name)
  discard vm.globals.tableSet(asObjString(internedVal), valObj(nativeObj))

proc freeVM*(vm: var VM) =
  var current = vm.objects
  while current != nil:
    let header = cast[ptr ObjHeader](current)
    let nextObj = header.next
    case header.kind
    of objString:
      let sObj = cast[ptr ObjString](current)
      sObj.strVal = ""
      dealloc(sObj)
    of objFunction:
      let fObj = cast[ptr ObjFunction](current)
      fObj.name = ""
      fObj.chunk.code = @[]
      fObj.chunk.constants = @[]
      fObj.chunk.lines = @[]
      dealloc(fObj)
    of objNative:
      let nObj = cast[ptr ObjNative](current)
      nObj.name = ""
      dealloc(nObj)
    of objUserData:
      let uObj = cast[ptr ObjUserData](current)
      if uObj.finalizer != nil and uObj.data != nil:
        uObj.finalizer(uObj.data)
      dealloc(uObj)
    current = nextObj

  vm.objects = nil
  if vm.globals.entries != nil: dealloc(vm.globals.entries)
  if vm.strings.entries != nil: dealloc(vm.strings.entries)
  vm.globals = FlatTable()
  vm.strings = FlatTable()
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
      if vm.stackTop == 0:
        return false # Stack was reset due to runtime error
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

    of opGetLocal0..opGetLocal3:
      let slot = int(instruction) - int(opGetLocal0)
      vm.push(vm.stack[frame.slots + slot])

    of opSetLocal0..opSetLocal3:
      let slot = int(instruction) - int(opSetLocal0)
      vm.stack[frame.slots + slot] = vm.peek(0)

    of opDefineGlobal:
      let nameObj = frame.readString()
      discard vm.globals.tableSet(nameObj, vm.pop())

    of opGetGlobal:
      let nameObj = frame.readString()
      var val: Value
      if not tableGet(addr vm.globals, nameObj, val):
        vm.runtimeError("Undefined variable '" & nameObj.strVal & "'.")
        return irRuntimeError
      vm.push(val)

    of opSetGlobal:
      let nameObj = frame.readString()
      var val: Value
      if not tableGet(addr vm.globals, nameObj, val):
        vm.runtimeError("Undefined variable '" & nameObj.strVal & "'.")
        return irRuntimeError
      discard vm.globals.tableSet(nameObj, vm.peek(0))

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
        let strVal = internStringImpl(addr vm, concatStr)
        vm.push(strVal)
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
  vm.isCompiling = true
  let scriptFn = compile(source, addr vm, internStringImpl, newFunctionImpl)
  vm.isCompiling = false
  if scriptFn == nil:
    return irCompileError

  vm.push(valObj(scriptFn))
  discard vm.call(scriptFn, 0)
  return vm.run()
