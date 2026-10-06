## vm.nim - High-Performance CallFrame, FlatTable, Lexical Closures & Mark-Sweep VM

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
    closure*: ptr ObjClosure
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
    openUpvalues*: ptr ObjUpvalue
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
  result.openUpvalues = nil
  result.grayStack = @[]
  result.bytesAllocated = 0
  result.nextGC = 1024 * 1024
  result.isCompiling = false
  result.output = ""

proc resetStack*(vm: var VM) =
  vm.stackTop = 0
  vm.frameCount = 0

proc runtimeError*(vm: var VM, message: string) =
  stderr.write("Runtime Error: " & message & "\n")
  for i in countdown(vm.frameCount - 1, 0):
    let frame = addr vm.frames[i]
    let fn = frame.closure.function
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
  if isObjKind(value, objString): return asObjString(value).length > 0
  return true

# FlatTable Operations
proc isSlotEmpty(entry: ptr Entry): bool =
  return entry.key == nil and (uint64(entry.val) == 0 or isNil(entry.val))

proc findEntry*(entries: ptr UncheckedArray[Entry], capacityMask: int, key: ptr ObjString): ptr Entry =
  var index = int(key.hash) and capacityMask
  var tombstone: ptr Entry = nil
  for _ in 0 .. capacityMask:
    let entry = addr entries[index]
    if entry.key == nil:
      if isSlotEmpty(entry):
        return if tombstone != nil: tombstone else: entry
      else:
        if tombstone == nil: tombstone = entry
    elif entry.key == key:
      return entry
    elif entry.key.hash == key.hash and entry.key.length == key.length:
      if key.length == 0 or equalMem(addr entry.key.chars[0], addr key.chars[0], key.length):
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
  of objUpvalue:
    vm.markValue(cast[ptr ObjUpvalue](objPtr).closed)
  of objFunction:
    let fn = cast[ptr ObjFunction](objPtr)
    for constVal in fn.chunk.constants:
      vm.markValue(constVal)
  of objClosure:
    let closure = cast[ptr ObjClosure](objPtr)
    vm.markObject(cast[pointer](closure.function))
    for i in 0 ..< closure.upvalueCount:
      vm.markObject(cast[pointer](closure.upvalues[i]))

proc collectGarbage*(vm: var VM) =
  # Mark Roots
  for i in 0 ..< vm.stackTop:
    vm.markValue(vm.stack[i])

  for i in 0 ..< vm.frameCount:
    vm.markObject(cast[pointer](vm.frames[i].closure))

  var upvalue = vm.openUpvalues
  while upvalue != nil:
    vm.markObject(cast[pointer](upvalue))
    upvalue = upvalue.next

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
        entry.val = valBool(true) # Tombstone
        dec vm.strings.count

  # Sweep Objects Linked List
  var previous: pointer = nil
  var current = vm.objects

  while current != nil:
    let header = cast[ptr ObjHeader](current)
    let nextObj = header.next
    if header.isMarked:
      header.isMarked = false
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
        dealloc(unreached)
      of objFunction:
        let fObj = cast[ptr ObjFunction](unreached)
        fObj.name = ""
        fObj.chunk.code = @[]
        fObj.chunk.constants = @[]
        fObj.chunk.lines = @[]
        dealloc(fObj)
      of objClosure:
        let cObj = cast[ptr ObjClosure](unreached)
        if cObj.upvalues != nil: dealloc(cObj.upvalues)
        dealloc(cObj)
      of objUpvalue:
        dealloc(unreached)
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

proc newFunctionImpl*(vmPtr: pointer, name: string = ""): ptr ObjFunction {.nimcall.} =
  let vm = cast[ptr VM](vmPtr)
  let fn = cast[ptr ObjFunction](alloc0(sizeof(ObjFunction)))
  fn.header = ObjHeader(kind: objFunction)
  fn.arity = 0
  fn.upvalueCount = 0
  fn.name = name
  fn.chunk = Chunk(code: @[], constants: @[], lines: @[])
  vm[].trackObject(cast[pointer](fn))
  return fn

proc newClosure*(vm: var VM, fn: ptr ObjFunction): ptr ObjClosure =
  let closure = cast[ptr ObjClosure](alloc0(sizeof(ObjClosure)))
  closure.header = ObjHeader(kind: objClosure)
  closure.function = fn
  closure.upvalueCount = fn.upvalueCount
  if fn.upvalueCount > 0:
    closure.upvalues = cast[ptr UncheckedArray[ptr ObjUpvalue]](alloc0(sizeof(ptr ObjUpvalue) * fn.upvalueCount))
  vm.trackObject(cast[pointer](closure))
  return closure

proc newUpvalue*(vm: var VM, slot: ptr Value): ptr ObjUpvalue =
  let upvalue = cast[ptr ObjUpvalue](alloc0(sizeof(ObjUpvalue)))
  upvalue.header = ObjHeader(kind: objUpvalue)
  upvalue.location = slot
  upvalue.closed = valNil()
  upvalue.next = nil
  vm.trackObject(cast[pointer](upvalue))
  return upvalue

proc captureUpvalue*(vm: var VM, local: ptr Value): ptr ObjUpvalue =
  var prevUpvalue: ptr ObjUpvalue = nil
  var upvalue = vm.openUpvalues

  while upvalue != nil and cast[uint64](upvalue.location) > cast[uint64](local):
    prevUpvalue = upvalue
    upvalue = upvalue.next

  if upvalue != nil and upvalue.location == local:
    return upvalue

  let createdUpvalue = vm.newUpvalue(local)
  createdUpvalue.next = upvalue

  if prevUpvalue == nil:
    vm.openUpvalues = createdUpvalue
  else:
    prevUpvalue.next = createdUpvalue

  return createdUpvalue

proc closeUpvalues*(vm: var VM, last: ptr Value) =
  while vm.openUpvalues != nil and cast[uint64](vm.openUpvalues.location) >= cast[uint64](last):
    let upvalue = vm.openUpvalues
    upvalue.closed = upvalue.location[]
    upvalue.location = addr upvalue.closed
    vm.openUpvalues = upvalue.next

proc internStringImpl*(vmPtr: pointer, str: string): Value {.nimcall.} =
  let vm = cast[ptr VM](vmPtr)
  var hash = 2166136261'u32
  for c in str:
    hash = hash xor uint8(c)
    hash = hash * 16777619'u32

  let tempSize = sizeof(ObjString) + str.len + 1
  let tempBuf = alloc0(tempSize)
  let tempObj = cast[ptr ObjString](tempBuf)
  tempObj.header = ObjHeader(kind: objString)
  tempObj.hash = hash
  tempObj.length = str.len
  if str.len > 0:
    copyMem(addr tempObj.chars[0], unsafeAddr str[0], str.len)
  tempObj.chars[str.len] = '\0'

  if vm.strings.entries != nil:
    let entry = findEntry(vm.strings.entries, vm.strings.capacityMask, tempObj)
    if entry.key != nil:
      dealloc(tempBuf)
      return valObj(entry.key)

  dealloc(tempBuf)
  let obj = cast[ptr ObjString](alloc0(tempSize))
  obj.header = ObjHeader(kind: objString)
  obj.hash = hash
  obj.length = str.len
  if str.len > 0:
    copyMem(addr obj.chars[0], unsafeAddr str[0], str.len)
  obj.chars[str.len] = '\0'

  discard vm[].strings.tableSet(obj, valBool(true))
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
      dealloc(current)
    of objFunction:
      let fObj = cast[ptr ObjFunction](current)
      fObj.name = ""
      fObj.chunk.code = @[]
      fObj.chunk.constants = @[]
      fObj.chunk.lines = @[]
      dealloc(fObj)
    of objClosure:
      let cObj = cast[ptr ObjClosure](current)
      if cObj.upvalues != nil: dealloc(cObj.upvalues)
      dealloc(cObj)
    of objUpvalue:
      dealloc(current)
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
  vm.openUpvalues = nil
  vm.resetStack()

proc call*(vm: var VM, closure: ptr ObjClosure, argCount: int): bool =
  if argCount != closure.function.arity:
    vm.runtimeError("Expected " & $closure.function.arity & " arguments but got " & $argCount & ".")
    return false

  if vm.frameCount == FRAMES_MAX:
    vm.runtimeError("Call frame overflow.")
    return false

  var frame = addr vm.frames[vm.frameCount]
  inc vm.frameCount
  frame.closure = closure
  frame.ip = 0
  frame.slots = vm.stackTop - argCount - 1
  return true

proc callValue*(vm: var VM, callee: Value, argCount: int): bool =
  if isObj(callee):
    case cast[ptr ObjHeader](asObj(callee)).kind
    of objClosure:
      return vm.call(asObjClosure(callee), argCount)
    of objFunction:
      let closure = vm.newClosure(asObjFunction(callee))
      vm.stack[vm.stackTop - argCount - 1] = valObj(closure)
      return vm.call(closure, argCount)
    of objNative:
      let nativeFn = asObjNative(callee)
      let calleeSlot = vm.stackTop - argCount - 1
      let argsPtr = cast[ptr UncheckedArray[Value]](addr vm.stack[calleeSlot + 1])
      let resVal = nativeFn.fn(addr vm, argCount, argsPtr)
      if vm.stackTop == 0 and calleeSlot < 0:
        return false
      vm.stackTop = calleeSlot
      vm.push(resVal)
      return true
    else: discard

  vm.runtimeError("Can only call functions and classes.")
  return false

proc readByte*(frame: ptr CallFrame): uint8 =
  result = frame.closure.function.chunk.code[frame.ip]
  inc frame.ip

proc readShort*(frame: ptr CallFrame): uint16 =
  let high = uint16(frame.closure.function.chunk.code[frame.ip]) shl 8
  let low = uint16(frame.closure.function.chunk.code[frame.ip + 1])
  frame.ip += 2
  return high or low

proc readConstant*(frame: ptr CallFrame): Value =
  let index = frame.readByte()
  return frame.closure.function.chunk.constants[int(index)]

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

    of opGetUpvalue:
      let slot = frame.readByte()
      vm.push(frame.closure.upvalues[slot].location[])

    of opSetUpvalue:
      let slot = frame.readByte()
      frame.closure.upvalues[slot].location[] = vm.peek(0)

    of opDefineGlobal:
      let nameObj = frame.readString()
      discard vm.globals.tableSet(nameObj, vm.pop())

    of opGetGlobal:
      let nameObj = frame.readString()
      var val: Value
      if not tableGet(addr vm.globals, nameObj, val):
        vm.runtimeError("Undefined variable '" & getString(nameObj) & "'.")
        return irRuntimeError
      vm.push(val)

    of opSetGlobal:
      let nameObj = frame.readString()
      var val: Value
      if not tableGet(addr vm.globals, nameObj, val):
        vm.runtimeError("Undefined variable '" & getString(nameObj) & "'.")
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
        vm.push(valBool(getString(asObjString(a)) > getString(asObjString(b))))
      else:
        vm.runtimeError("Operands must be two numbers or two strings.")
        return irRuntimeError

    of opLess:
      let b = vm.pop()
      let a = vm.pop()
      if isNum(a) and isNum(b):
        vm.push(valBool(asNum(a) < asNum(b)))
      elif isObjKind(a, objString) and isObjKind(b, objString):
        vm.push(valBool(getString(asObjString(a)) < getString(asObjString(b))))
      else:
        vm.runtimeError("Operands must be two numbers or two strings.")
        return irRuntimeError

    of opAdd:
      let b = vm.pop()
      let a = vm.pop()
      if isNum(a) and isNum(b):
        vm.push(valNum(asNum(a) + asNum(b)))
      elif isObjKind(a, objString) and isObjKind(b, objString):
        let concatStr = getString(asObjString(a)) & getString(asObjString(b))
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

    of opClosure:
      let fn = asObjFunction(frame.readConstant())
      let closure = vm.newClosure(fn)
      vm.push(valObj(closure))
      for i in 0 ..< closure.upvalueCount:
        let isLocal = frame.readByte() == 1'u8
        let index = int(frame.readByte())
        if isLocal:
          closure.upvalues[i] = vm.captureUpvalue(addr vm.stack[frame.slots + index])
        else:
          closure.upvalues[i] = frame.closure.upvalues[index]

    of opCloseUpvalue:
      vm.closeUpvalues(addr vm.stack[vm.stackTop - 1])
      discard vm.pop()

    of opReturn:
      let resVal = vm.pop()
      vm.closeUpvalues(addr vm.stack[frame.slots])
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

  let scriptClosure = vm.newClosure(scriptFn)
  vm.push(valObj(scriptClosure))
  discard vm.call(scriptClosure, 0)
  return vm.run()
