## compiler.nim - Single-pass Pratt Parser & Bytecode Compiler for lightweight Nim engine

import lexer

type
  ValueKind* = enum
    vkNil, vkBool, vkNumber, vkString

  Value* = object
    case kind*: ValueKind
    of vkNil: discard
    of vkBool: boolVal*: bool
    of vkNumber: numberVal*: float64
    of vkString: strVal*: string

  OpCode* = enum
    opConstant,
    opNil,
    opTrue,
    opFalse,
    opPop,
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
    opReturn

  Chunk* = object
    code*: seq[uint8]
    constants*: seq[Value]
    lines*: seq[int]

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

  Compiler* = object
    lexer*: Lexer
    current*: Token
    previous*: Token
    chunk*: Chunk
    hadError*: bool
    panicMode*: bool

proc initCompiler*(source: string): Compiler =
  result.lexer = initLexer(source)
  result.chunk = Chunk(code: @[], constants: @[], lines: @[])
  result.hadError = false
  result.panicMode = false

proc `$`*(v: Value): string =
  case v.kind
  of vkNil: "nil"
  of vkBool: $v.boolVal
  of vkNumber: $v.numberVal
  of vkString: v.strVal

proc valuesEqual*(a, b: Value): bool =
  if a.kind != b.kind: return false
  case a.kind
  of vkNil: return true
  of vkBool: return a.boolVal == b.boolVal
  of vkNumber: return a.numberVal == b.numberVal
  of vkString: return a.strVal == b.strVal

proc emitByte*(compiler: var Compiler, byteVal: uint8) =
  compiler.chunk.code.add(byteVal)
  compiler.chunk.lines.add(compiler.previous.line)

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
  return compiler.chunk.code.len - 2

proc patchJump*(compiler: var Compiler, offset: int) =
  let jump = compiler.chunk.code.len - offset - 2
  if jump > 65535:
    compiler.hadError = true
    # Error: Too much code to jump over.
    return
  compiler.chunk.code[offset] = uint8((jump shr 8) and 0xFF)
  compiler.chunk.code[offset + 1] = uint8(jump and 0xFF)

proc emitLoop*(compiler: var Compiler, loopStart: int) =
  compiler.emitOp(opLoop)
  let jump = compiler.chunk.code.len - loopStart + 2
  if jump > 65535:
    compiler.hadError = true
  compiler.emitByte(uint8((jump shr 8) and 0xFF))
  compiler.emitByte(uint8(jump and 0xFF))

proc addConstant*(compiler: var Compiler, value: Value): uint16 =
  # Search existing constants to save space
  for i in 0 ..< compiler.chunk.constants.len:
    if valuesEqual(compiler.chunk.constants[i], value):
      return uint16(i)
  compiler.chunk.constants.add(value)
  let index = compiler.chunk.constants.len - 1
  if index > 65535:
    compiler.hadError = true
    return 0
  return uint16(index)

proc emitConstant*(compiler: var Compiler, value: Value) =
  let constant = compiler.addConstant(value)
  if constant <= 255:
    compiler.emitOpAndByte(opConstant, uint8(constant))
  else:
    # We could support opConstant16 if needed, for simplicity 256 constants per chunk/script
    compiler.emitOpAndByte(opConstant, uint8(constant and 0xFF))

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
    compiler.current = compiler.lexer.nextToken()
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

# Forward declarations for Pratt parser
proc expression*(compiler: var Compiler)
proc statement*(compiler: var Compiler)
proc declaration*(compiler: var Compiler)
proc parsePrecedence*(compiler: var Compiler, precedence: Precedence)
proc getRule*(kind: TokenType): ParseRule

proc number*(compiler: var Compiler, canAssign: bool) =
  let value = Value(kind: vkNumber, numberVal: compiler.previous.numberVal)
  compiler.emitConstant(value)

proc stringExpr*(compiler: var Compiler, canAssign: bool) =
  let value = Value(kind: vkString, strVal: compiler.previous.strVal)
  compiler.emitConstant(value)

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

proc identifierConstant*(compiler: var Compiler, name: Token): uint16 =
  let value = Value(kind: vkString, strVal: name.lexeme)
  return compiler.addConstant(value)

proc variable*(compiler: var Compiler, canAssign: bool) =
  let arg = compiler.identifierConstant(compiler.previous)
  if canAssign and compiler.match(tkAssign):
    compiler.expression()
    compiler.emitOpAndByte(opSetGlobal, uint8(arg and 0xFF))
  else:
    compiler.emitOpAndByte(opGetGlobal, uint8(arg and 0xFF))

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
  of tkLParen: ParseRule(prefix: grouping, infix: nil, precedence: precNone)
  of tkMinus: ParseRule(prefix: unary, infix: binary, precedence: precTerm)
  of tkPlus: ParseRule(prefix: nil, infix: binary, precedence: precTerm)
  of tkSlash: ParseRule(prefix: nil, infix: binary, precedence: precFactor)
  of tkStar: ParseRule(prefix: nil, infix: binary, precedence: precFactor)
  of tkBang: ParseRule(prefix: unary, infix: nil, precedence: precNone)
  of tkNotEq: ParseRule(prefix: nil, infix: binary, precedence: precEquality)
  of tkEq: ParseRule(prefix: nil, infix: binary, precedence: precEquality)
  of tkGt, tkGtEq, tkLt, tkLtEq: ParseRule(prefix: nil, infix: binary, precedence: precComparison)
  of tkIdentifier: ParseRule(prefix: variable, infix: nil, precedence: precNone)
  of tkString: ParseRule(prefix: stringExpr, infix: nil, precedence: precNone)
  of tkNumber: ParseRule(prefix: number, infix: nil, precedence: precNone)
  of tkFalse, tkTrue, tkNil: ParseRule(prefix: literal, infix: nil, precedence: precNone)
  else: ParseRule(prefix: nil, infix: nil, precedence: precNone)

proc expression*(compiler: var Compiler) =
  compiler.parsePrecedence(precAssignment)

proc printStatement*(compiler: var Compiler) =
  compiler.expression()
  compiler.consume(tkSemicolon, "Expect ';' after value.")
  compiler.emitOp(opPrint)

proc expressionStatement*(compiler: var Compiler) =
  compiler.expression()
  compiler.consume(tkSemicolon, "Expect ';' after expression.")
  compiler.emitOp(opPop)

proc blockStatement*(compiler: var Compiler) =
  while not compiler.check(tkRBrace) and not compiler.check(tkEof):
    compiler.declaration()
  compiler.consume(tkRBrace, "Expect '}' after block.")

proc ifStatement*(compiler: var Compiler) =
  compiler.consume(tkLParen, "Expect '(' after 'if'.")
  compiler.expression()
  compiler.consume(tkRParen, "Expect ')' after condition.")

  let thenJump = compiler.emitJump(opJumpIfFalse)
  compiler.emitOp(opPop) # Pop condition on true path

  if compiler.match(tkLBrace):
    compiler.blockStatement()
  else:
    compiler.statement()

  let elseJump = compiler.emitJump(opJump)
  compiler.patchJump(thenJump)
  compiler.emitOp(opPop) # Pop condition on false path

  if compiler.match(tkElse):
    if compiler.match(tkLBrace):
      compiler.blockStatement()
    else:
      compiler.statement()

  compiler.patchJump(elseJump)

proc whileStatement*(compiler: var Compiler) =
  let loopStart = compiler.chunk.code.len
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
  if compiler.match(tkSemicolon):
    compiler.emitOp(opNil)
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

proc parseVariable*(compiler: var Compiler, errorMessage: string): uint16 =
  compiler.consume(tkIdentifier, errorMessage)
  return compiler.identifierConstant(compiler.previous)

proc defineVariable*(compiler: var Compiler, global: uint16) =
  compiler.emitOpAndByte(opDefineGlobal, uint8(global and 0xFF))

proc varDeclaration*(compiler: var Compiler) =
  let global = compiler.parseVariable("Expect variable name.")
  if compiler.match(tkAssign):
    compiler.expression()
  else:
    compiler.emitOp(opNil)
  compiler.consume(tkSemicolon, "Expect ';' after variable declaration.")
  compiler.defineVariable(global)

proc declaration*(compiler: var Compiler) =
  if compiler.match(tkVar):
    compiler.varDeclaration()
  else:
    compiler.statement()

  if compiler.panicMode:
    compiler.synchronize()

proc compile*(source: string, chunk: var Chunk): bool =
  var compiler = initCompiler(source)
  compiler.advance()

  while not compiler.match(tkEof):
    compiler.declaration()

  compiler.emitOp(opReturn)
  chunk = compiler.chunk
  return not compiler.hadError
