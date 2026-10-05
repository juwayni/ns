## compiler.nim - 8-Byte NaN-Tagged Single-Pass Pratt Compiler & Local Resolver

import lexer

# --------------------------------------------------
# 8-Byte NaN-Tagged Value Representation
# --------------------------------------------------

type
  Value* = distinct uint64

const
  QNAN: uint64     = 0x7ffc000000000000'u64
  SIGN_BIT: uint64 = 0x8000000000000000'u64

  TAG_NIL: uint64   = 1
  TAG_FALSE: uint64 = 2
  TAG_TRUE: uint64  = 3

template valNil*(): Value = Value(QNAN or TAG_NIL)
template valBool*(b: bool): Value = Value(QNAN or (if b: TAG_TRUE else: TAG_FALSE))
template valNum*(num: float64): Value = cast[Value](num)
template valObj*(p: pointer): Value = Value(SIGN_BIT or QNAN or (cast[uint64](p) and 0x0000FFFFFFFFFFFF'u64))

template isNil*(v: Value): bool = uint64(v) == (QNAN or TAG_NIL)
template isBool*(v: Value): bool = (uint64(v) and not 1'u64) == (QNAN or TAG_FALSE)
template asBool*(v: Value): bool = uint64(v) == (QNAN or TAG_TRUE)

template isNum*(v: Value): bool = (uint64(v) and QNAN) != QNAN
template asNum*(v: Value): float64 = cast[float64](v)

template isObj*(v: Value): bool = (uint64(v) and (SIGN_BIT or QNAN)) == (SIGN_BIT or QNAN)
template asObj*(v: Value): pointer = cast[pointer](uint64(v) and 0x0000FFFFFFFFFFFF'u64)

# --------------------------------------------------
# Heap Objects (ObjString, ObjFunction, ObjNative, ObjUserData)
# --------------------------------------------------

type
  ObjKind* = enum
    objString,
    objFunction,
    objNative,
    objUserData

  ObjHeader* = object
    kind*: ObjKind
    isMarked*: bool
    next*: pointer # Linked list for GC sweep

  ObjString* = object
    header*: ObjHeader
    strVal*: string
    hash*: uint32

  Chunk* = object
    code*: seq[uint8]
    constants*: seq[Value]
    lines*: seq[int]

  ObjFunction* = object
    header*: ObjHeader
    arity*: int
    chunk*: Chunk
    name*: string

  NativeFn* = proc(vm: pointer, argc: int, args: ptr UncheckedArray[Value]): Value {.nimcall.}

  ObjNative* = object
    header*: ObjHeader
    name*: string
    fn*: NativeFn

  ObjUserData* = object
    header*: ObjHeader
    typeId*: int
    finalizer*: proc(p: pointer) {.nimcall.}
    data*: pointer

proc isObjKind*(v: Value, kind: ObjKind): bool =
  if not isObj(v): return false
  let ptrHeader = cast[ptr ObjHeader](asObj(v))
  if ptrHeader == nil: return false
  return ptrHeader.kind == kind

proc asObjString*(v: Value): ptr ObjString =
  cast[ptr ObjString](asObj(v))

proc asObjFunction*(v: Value): ptr ObjFunction =
  cast[ptr ObjFunction](asObj(v))

proc asObjNative*(v: Value): ptr ObjNative =
  cast[ptr ObjNative](asObj(v))

proc asObjUserData*(v: Value): ptr ObjUserData =
  cast[ptr ObjUserData](asObj(v))

proc `==`*(a, b: Value): bool =
  uint64(a) == uint64(b)

proc valuesEqual*(a, b: Value): bool =
  if isNum(a) and isNum(b): return asNum(a) == asNum(b)
  if isObjKind(a, objString) and isObjKind(b, objString):
    # O(1) Pointer Equality thanks to 100% strict String Interning!
    return asObj(a) == asObj(b)
  return uint64(a) == uint64(b)

proc `$`*(v: Value): string =
  if isNil(v): return "nil"
  if isBool(v): return $asBool(v)
  if isNum(v): return $asNum(v)
  if isObj(v):
    let ptrHeader = cast[ptr ObjHeader](asObj(v))
    if ptrHeader == nil: return "<null obj>"
    case ptrHeader.kind
    of objString: return asObjString(v).strVal
    of objFunction:
      let fn = asObjFunction(v)
      if fn.name.len == 0: return "<script>"
      else: return "<fn " & fn.name & ">"
    of objNative: return "<native fn " & asObjNative(v).name & ">"
    of objUserData: return "<userdata>"
  return "<unknown>"

# --------------------------------------------------
# OpCodes
# --------------------------------------------------

type
  OpCode* = enum
    opConstant,
    opNil,
    opTrue,
    opFalse,
    opPop,
    opGetLocal,
    opSetLocal,
    opGetLocal0,
    opGetLocal1,
    opGetLocal2,
    opGetLocal3,
    opSetLocal0,
    opSetLocal1,
    opSetLocal2,
    opSetLocal3,
    opDefineGlobal,
    opGetGlobal,
    opSetGlobal,
    opEqual,
    opGreater,
    opLess,
    opAdd,
    opSubtract,
    opMultiply,
    opDivide,
    opNot,
    opNegate,
    opPrint,
    opJumpIfFalse,
    opJump,
    opLoop,
    opCall,
    opReturn

# --------------------------------------------------
# Compiler & Pratt Parsing
# --------------------------------------------------

type
  Precedence* = enum
    precNone,
    precAssignment, # =
    precOr,         # or
    precAnd,        # and
    precEquality,   # == !=
    precComparison, # < > <= >=
    precTerm,       # + -
    precFactor,     # * /
    precUnary,      # ! -
    precCall,       # . ()
    precPrimary

  ParseFn* = proc(compiler: var Compiler, canAssign: bool)

  ParseRule* = object
    prefix*: ParseFn
    infix*: ParseFn
    precedence*: Precedence

  Local* = object
    name*: Token
    depth*: int

  FunctionType* = enum
    ftScript,
    ftFunction

  Compiler* = object
    enclosing*: ptr Compiler
    function*: ptr ObjFunction
    functionType*: FunctionType
    lexer*: ptr Lexer # Shared pointer across nested function compilers
    vm*: pointer     # Pointer to VM for GC tracking & String Interning
    internStringProc*: proc(vm: pointer, s: string): Value {.nimcall.}
    newFunctionProc*: proc(vm: pointer, name: string): ptr ObjFunction {.nimcall.}
    current*: Token
    previous*: Token
    locals*: array[256, Local]
    localCount*: int
    scopeDepth*: int
    hadError*: bool
    panicMode*: bool

proc currentChunk*(compiler: var Compiler): ptr Chunk =
  addr compiler.function.chunk

proc emitByte*(compiler: var Compiler, byteVal: uint8) =
  let chunk = compiler.currentChunk()
  chunk.code.add(byteVal)
  chunk.lines.add(compiler.previous.line)

proc emitOp*(compiler: var Compiler, op: OpCode) =
  compiler.emitByte(uint8(ord(op)))

proc emitBytes*(compiler: var Compiler, byte1, byte2: uint8) =
  compiler.emitByte(byte1)
  compiler.emitByte(byte2)

proc emitOpAndByte*(compiler: var Compiler, op: OpCode, byteVal: uint8) =
  compiler.emitOp(op)
  compiler.emitByte(byteVal)

proc emitJump*(compiler: var Compiler, op: OpCode): int =
  compiler.emitOp(op)
  compiler.emitByte(0xFF)
  compiler.emitByte(0xFF)
  return compiler.currentChunk().code.len - 2

proc patchJump*(compiler: var Compiler, offset: int) =
  let jump = compiler.currentChunk().code.len - offset - 2
  if jump > 65535:
    compiler.hadError = true
    return
  compiler.currentChunk().code[offset] = uint8((jump shr 8) and 0xFF)
  compiler.currentChunk().code[offset + 1] = uint8(jump and 0xFF)

proc emitLoop*(compiler: var Compiler, loopStart: int) =
  compiler.emitOp(opLoop)
  let jump = compiler.currentChunk().code.len - loopStart + 2
  if jump > 65535:
    compiler.hadError = true
  compiler.emitByte(uint8((jump shr 8) and 0xFF))
  compiler.emitByte(uint8(jump and 0xFF))

proc addConstant*(compiler: var Compiler, value: Value): uint16 =
  let chunk = compiler.currentChunk()
  for i in 0 ..< chunk.constants.len:
    if valuesEqual(chunk.constants[i], value):
      return uint16(i)
  chunk.constants.add(value)
  let index = chunk.constants.len - 1
  if index > 65535:
    compiler.hadError = true
    return 0
  return uint16(index)

proc emitConstant*(compiler: var Compiler, value: Value) =
  let constant = compiler.addConstant(value)
  if constant > 255:
    compiler.hadError = true
    stderr.write("Too many constants in one chunk.\n")
    return
  compiler.emitOpAndByte(opConstant, uint8(constant))

proc initCompiler*(compiler: var Compiler,
                 lexerPtr: ptr Lexer,
                 vmPtr: pointer,
                 internStringProc: proc(vm: pointer, s: string): Value {.nimcall.},
                 newFunctionProc: proc(vm: pointer, name: string): ptr ObjFunction {.nimcall.},
                 fnType: FunctionType = ftScript,
                 fnName: string = "",
                 enclosing: ptr Compiler = nil) =
  compiler.enclosing = enclosing
  compiler.lexer = lexerPtr
  compiler.vm = vmPtr
  compiler.internStringProc = internStringProc
  compiler.newFunctionProc = newFunctionProc
  compiler.function = newFunctionProc(vmPtr, fnName)
  compiler.functionType = fnType
  compiler.localCount = 0
  compiler.scopeDepth = 0
  compiler.hadError = false
  compiler.panicMode = false

  # Claim local slot 0 for VM internal call frame reserve
  compiler.locals[0] = Local(name: Token(lexeme: ""), depth: 0)
  inc compiler.localCount

proc errorAt*(compiler: var Compiler, token: Token, message: string) =
  if compiler.panicMode: return
  compiler.panicMode = true
  compiler.hadError = true
  stderr.write("[line " & $token.line & "] Error")
  if token.kind == tkEof:
    stderr.write(" at end")
  elif token.kind == tkError:
    discard
  else:
    stderr.write(" at '" & token.lexeme & "'")
  stderr.write(": " & message & "\n")

proc error*(compiler: var Compiler, message: string) =
  compiler.errorAt(compiler.previous, message)

proc errorAtCurrent*(compiler: var Compiler, message: string) =
  compiler.errorAt(compiler.current, message)

proc advance*(compiler: var Compiler) =
  compiler.previous = compiler.current
  while true:
    compiler.current = compiler.lexer[].nextToken()
    if compiler.current.kind != tkError: break
    compiler.errorAtCurrent(compiler.current.errorMsg)

proc consume*(compiler: var Compiler, kind: TokenType, message: string) =
  if compiler.current.kind == kind:
    compiler.advance()
    return
  compiler.errorAtCurrent(message)

proc check*(compiler: Compiler, kind: TokenType): bool =
  compiler.current.kind == kind

proc match*(compiler: var Compiler, kind: TokenType): bool =
  if not compiler.check(kind): return false
  compiler.advance()
  return true

# Forward declarations
proc expression*(compiler: var Compiler)
proc statement*(compiler: var Compiler)
proc declaration*(compiler: var Compiler)
proc parsePrecedence*(compiler: var Compiler, precedence: Precedence)
proc getRule*(kind: TokenType): ParseRule

proc number*(compiler: var Compiler, canAssign: bool) =
  compiler.emitConstant(valNum(compiler.previous.numberVal))

proc stringExpr*(compiler: var Compiler, canAssign: bool) =
  # Strict String Interning via VM GC pool!
  let strVal = compiler.internStringProc(compiler.vm, compiler.previous.strVal)
  compiler.emitConstant(strVal)

proc literal*(compiler: var Compiler, canAssign: bool) =
  case compiler.previous.kind
  of tkNil: compiler.emitOp(opNil)
  of tkTrue: compiler.emitOp(opTrue)
  of tkFalse: compiler.emitOp(opFalse)
  else: return

proc grouping*(compiler: var Compiler, canAssign: bool) =
  compiler.expression()
  compiler.consume(tkRParen, "Expect ')' after expression.")

proc unary*(compiler: var Compiler, canAssign: bool) =
  let operatorKind = compiler.previous.kind
  compiler.parsePrecedence(precUnary)
  case operatorKind
  of tkBang: compiler.emitOp(opNot)
  of tkMinus: compiler.emitOp(opNegate)
  else: return

proc binary*(compiler: var Compiler, canAssign: bool) =
  let operatorKind = compiler.previous.kind
  let rule = getRule(operatorKind)
  compiler.parsePrecedence(Precedence(ord(rule.precedence) + 1))

  case operatorKind
  of tkPlus: compiler.emitOp(opAdd)
  of tkMinus: compiler.emitOp(opSubtract)
  of tkStar: compiler.emitOp(opMultiply)
  of tkSlash: compiler.emitOp(opDivide)
  of tkNotEq:
    compiler.emitOp(opEqual)
    compiler.emitOp(opNot)
  of tkEq: compiler.emitOp(opEqual)
  of tkGt: compiler.emitOp(opGreater)
  of tkGtEq:
    compiler.emitOp(opLess)
    compiler.emitOp(opNot)
  of tkLt: compiler.emitOp(opLess)
  of tkLtEq:
    compiler.emitOp(opGreater)
    compiler.emitOp(opNot)
  else: return

proc argumentList*(compiler: var Compiler): uint8 =
  var argCount: uint8 = 0
  if not compiler.check(tkRParen):
    while true:
      compiler.expression()
      if argCount == 255:
        compiler.error("Cannot have more than 255 arguments.")
      inc argCount
      if not compiler.match(tkComma): break
  compiler.consume(tkRParen, "Expect ')' after arguments.")
  return argCount

proc call*(compiler: var Compiler, canAssign: bool) =
  let argCount = compiler.argumentList()
  compiler.emitOpAndByte(opCall, argCount)

proc andExpr*(compiler: var Compiler, canAssign: bool) =
  let endJump = compiler.emitJump(opJumpIfFalse)
  compiler.emitOp(opPop)
  compiler.parsePrecedence(precAnd)
  compiler.patchJump(endJump)

proc orExpr*(compiler: var Compiler, canAssign: bool) =
  let elseJump = compiler.emitJump(opJumpIfFalse)
  let endJump = compiler.emitJump(opJump)
  compiler.patchJump(elseJump)
  compiler.emitOp(opPop)
  compiler.parsePrecedence(precOr)
  compiler.patchJump(endJump)

proc resolveLocal*(compiler: var Compiler, name: Token): int =
  for i in countdown(compiler.localCount - 1, 0):
    let local = compiler.locals[i]
    if local.name.lexeme == name.lexeme:
      if local.depth == -1:
        compiler.error("Cannot read local variable in its own initializer.")
      return i
  return -1

proc identifierConstant*(compiler: var Compiler, name: Token): uint16 =
  let strVal = compiler.internStringProc(compiler.vm, name.lexeme)
  return compiler.addConstant(strVal)

proc variable*(compiler: var Compiler, canAssign: bool) =
  var getOp, setOp: OpCode
  var arg: int = compiler.resolveLocal(compiler.previous)

  if arg != -1:
    getOp = opGetLocal
    setOp = opSetLocal
  else:
    arg = int(compiler.identifierConstant(compiler.previous))
    getOp = opGetGlobal
    setOp = opSetGlobal

  if canAssign and compiler.match(tkAssign):
    compiler.expression()
    if getOp == opGetLocal and arg >= 0 and arg <= 3:
      let fastSet = OpCode(ord(opSetLocal0) + arg)
      compiler.emitOp(fastSet)
    else:
      compiler.emitOpAndByte(setOp, uint8(arg and 0xFF))
  else:
    if getOp == opGetLocal and arg >= 0 and arg <= 3:
      let fastGet = OpCode(ord(opGetLocal0) + arg)
      compiler.emitOp(fastGet)
    else:
      compiler.emitOpAndByte(getOp, uint8(arg and 0xFF))

proc parsePrecedence*(compiler: var Compiler, precedence: Precedence) =
  compiler.advance()
  let prefixRule = getRule(compiler.previous.kind).prefix
  if prefixRule == nil:
    compiler.error("Expect expression.")
    return

  let canAssign = precedence <= precAssignment
  prefixRule(compiler, canAssign)

  while precedence <= getRule(compiler.current.kind).precedence:
    compiler.advance()
    let infixRule = getRule(compiler.previous.kind).infix
    infixRule(compiler, canAssign)

  if canAssign and compiler.match(tkAssign):
    compiler.error("Invalid assignment target.")

proc getRule*(kind: TokenType): ParseRule =
  case kind
  of tkLParen: ParseRule(prefix: grouping, infix: call, precedence: precCall)
  of tkMinus: ParseRule(prefix: unary, infix: binary, precedence: precTerm)
  of tkPlus: ParseRule(prefix: nil, infix: binary, precedence: precTerm)
  of tkSlash: ParseRule(prefix: nil, infix: binary, precedence: precFactor)
  of tkStar: ParseRule(prefix: nil, infix: binary, precedence: precFactor)
  of tkBang: ParseRule(prefix: unary, infix: nil, precedence: precNone)
  of tkNotEq: ParseRule(prefix: nil, infix: binary, precedence: precEquality)
  of tkEq: ParseRule(prefix: nil, infix: binary, precedence: precEquality)
  of tkGt, tkGtEq, tkLt, tkLtEq: ParseRule(prefix: nil, infix: binary, precedence: precComparison)
  of tkAnd: ParseRule(prefix: nil, infix: andExpr, precedence: precAnd)
  of tkOr: ParseRule(prefix: nil, infix: orExpr, precedence: precOr)
  of tkIdentifier: ParseRule(prefix: variable, infix: nil, precedence: precNone)
  of tkString: ParseRule(prefix: stringExpr, infix: nil, precedence: precNone)
  of tkNumber: ParseRule(prefix: number, infix: nil, precedence: precNone)
  of tkFalse, tkTrue, tkNil: ParseRule(prefix: literal, infix: nil, precedence: precNone)
  else: ParseRule(prefix: nil, infix: nil, precedence: precNone)

proc expression*(compiler: var Compiler) =
  compiler.parsePrecedence(precAssignment)

proc blockStatement*(compiler: var Compiler) =
  inc compiler.scopeDepth
  while not compiler.check(tkRBrace) and not compiler.check(tkEof):
    compiler.declaration()
  compiler.consume(tkRBrace, "Expect '}' after block.")
  dec compiler.scopeDepth

  # Pop out of scope local variables
  while compiler.localCount > 0 and compiler.locals[compiler.localCount - 1].depth > compiler.scopeDepth:
    compiler.emitOp(opPop)
    dec compiler.localCount

proc printStatement*(compiler: var Compiler) =
  compiler.expression()
  compiler.consume(tkSemicolon, "Expect ';' after value.")
  compiler.emitOp(opPrint)

proc expressionStatement*(compiler: var Compiler) =
  compiler.expression()
  compiler.consume(tkSemicolon, "Expect ';' after expression.")
  compiler.emitOp(opPop)

proc ifStatement*(compiler: var Compiler) =
  compiler.consume(tkLParen, "Expect '(' after 'if'.")
  compiler.expression()
  compiler.consume(tkRParen, "Expect ')' after condition.")

  let thenJump = compiler.emitJump(opJumpIfFalse)
  compiler.emitOp(opPop)

  if compiler.match(tkLBrace):
    compiler.blockStatement()
  else:
    compiler.statement()

  let elseJump = compiler.emitJump(opJump)
  compiler.patchJump(thenJump)
  compiler.emitOp(opPop)

  if compiler.match(tkElse):
    if compiler.match(tkLBrace):
      compiler.blockStatement()
    else:
      compiler.statement()

  compiler.patchJump(elseJump)

proc whileStatement*(compiler: var Compiler) =
  let loopStart = compiler.currentChunk().code.len
  compiler.consume(tkLParen, "Expect '(' after 'while'.")
  compiler.expression()
  compiler.consume(tkRParen, "Expect ')' after condition.")

  let exitJump = compiler.emitJump(opJumpIfFalse)
  compiler.emitOp(opPop)

  if compiler.match(tkLBrace):
    compiler.blockStatement()
  else:
    compiler.statement()

  compiler.emitLoop(loopStart)
  compiler.patchJump(exitJump)
  compiler.emitOp(opPop)

proc returnStatement*(compiler: var Compiler) =
  if compiler.functionType == ftScript:
    compiler.error("Cannot return from top-level code.")

  if compiler.match(tkSemicolon):
    compiler.emitOp(opNil)
    compiler.emitOp(opReturn)
  else:
    compiler.expression()
    compiler.consume(tkSemicolon, "Expect ';' after return value.")
    compiler.emitOp(opReturn)

proc synchronize*(compiler: var Compiler) =
  compiler.panicMode = false
  while compiler.current.kind != tkEof:
    if compiler.previous.kind == tkSemicolon: return
    case compiler.current.kind
    of tkIf, tkWhile, tkVar, tkPrint, tkReturn, tkFn:
      return
    else:
      discard
    compiler.advance()

proc statement*(compiler: var Compiler) =
  if compiler.match(tkPrint):
    compiler.printStatement()
  elif compiler.match(tkIf):
    compiler.ifStatement()
  elif compiler.match(tkWhile):
    compiler.whileStatement()
  elif compiler.match(tkReturn):
    compiler.returnStatement()
  elif compiler.match(tkLBrace):
    compiler.blockStatement()
  else:
    compiler.expressionStatement()

proc addLocal*(compiler: var Compiler, name: Token) =
  if compiler.localCount == 256:
    compiler.error("Too many local variables in function.")
    return
  var local = addr compiler.locals[compiler.localCount]
  inc compiler.localCount
  local.name = name
  local.depth = -1 # Uninitialized state

proc declareVariable*(compiler: var Compiler) =
  if compiler.scopeDepth == 0: return
  let name = compiler.previous
  for i in countdown(compiler.localCount - 1, 0):
    let local = compiler.locals[i]
    if local.depth != -1 and local.depth < compiler.scopeDepth:
      break
    if local.name.lexeme == name.lexeme:
      compiler.error("Already a variable with this name in this scope.")

  compiler.addLocal(name)

proc parseVariable*(compiler: var Compiler, errorMessage: string): uint16 =
  compiler.consume(tkIdentifier, errorMessage)
  compiler.declareVariable()
  if compiler.scopeDepth > 0: return 0
  return compiler.identifierConstant(compiler.previous)

proc markInitialized*(compiler: var Compiler) =
  if compiler.scopeDepth == 0: return
  compiler.locals[compiler.localCount - 1].depth = compiler.scopeDepth

proc defineVariable*(compiler: var Compiler, global: uint16) =
  if compiler.scopeDepth > 0:
    compiler.markInitialized()
    return
  compiler.emitOpAndByte(opDefineGlobal, uint8(global and 0xFF))

proc varDeclaration*(compiler: var Compiler) =
  let global = compiler.parseVariable("Expect variable name.")
  if compiler.match(tkAssign):
    compiler.expression()
  else:
    compiler.emitOp(opNil)
  compiler.consume(tkSemicolon, "Expect ';' after variable declaration.")
  compiler.defineVariable(global)

proc functionDecl*(compiler: var Compiler) =
  let global = compiler.parseVariable("Expect function name.")
  compiler.markInitialized()

  var fnCompiler: Compiler
  initCompiler(fnCompiler, compiler.lexer, compiler.vm, compiler.internStringProc, compiler.newFunctionProc, ftFunction, compiler.previous.lexeme, addr compiler)
  fnCompiler.current = compiler.current
  fnCompiler.previous = compiler.previous
  fnCompiler.scopeDepth = 1

  fnCompiler.consume(tkLParen, "Expect '(' after function name.")
  if not fnCompiler.check(tkRParen):
    while true:
      inc fnCompiler.function.arity
      if fnCompiler.function.arity > 255:
        fnCompiler.errorAtCurrent("Cannot have more than 255 parameters.")
      let paramConstant = fnCompiler.parseVariable("Expect parameter name.")
      fnCompiler.defineVariable(paramConstant)
      if not fnCompiler.match(tkComma): break

  fnCompiler.consume(tkRParen, "Expect ')' after parameters.")
  fnCompiler.consume(tkLBrace, "Expect '{' before function body.")
  fnCompiler.blockStatement()

  fnCompiler.emitOp(opNil)
  fnCompiler.emitOp(opReturn)

  compiler.current = fnCompiler.current
  compiler.previous = fnCompiler.previous

  let fnObj = fnCompiler.function
  let constant = compiler.addConstant(valObj(fnObj))
  compiler.emitOpAndByte(opConstant, uint8(constant and 0xFF))
  compiler.defineVariable(global)

proc declaration*(compiler: var Compiler) =
  if compiler.match(tkVar):
    compiler.varDeclaration()
  elif compiler.match(tkFn):
    compiler.functionDecl()
  else:
    compiler.statement()

  if compiler.panicMode:
    compiler.synchronize()

proc compile*(source: string,
              vmPtr: pointer,
              internStringProc: proc(vm: pointer, s: string): Value {.nimcall.},
              newFunctionProc: proc(vm: pointer, name: string): ptr ObjFunction {.nimcall.}): ptr ObjFunction =
  var lexer = initLexer(source)
  var compiler: Compiler
  initCompiler(compiler, addr lexer, vmPtr, internStringProc, newFunctionProc, ftScript, "")
  compiler.advance()

  while not compiler.match(tkEof):
    compiler.declaration()

  compiler.emitOp(opNil)
  compiler.emitOp(opReturn)

  if compiler.hadError:
    return nil
  return compiler.function
