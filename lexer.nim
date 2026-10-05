## lexer.nim - Pure char scanning lexer for lightweight Nim script engine

import std/strutils

type
  TokenType* = enum
    tkEof, tkError,

    # Operators & Punctuation
    tkPlus, tkMinus, tkStar, tkSlash,
    tkAssign, tkEq, tkBang, tkNotEq,
    tkLt, tkLtEq, tkGt, tkGtEq,
    tkLParen, tkRParen, tkLBrace, tkRBrace,
    tkComma, tkSemicolon,

    # Literals
    tkIdentifier, tkNumber, tkString,

    # Keywords
    tkIf, tkElse, tkWhile, tkFn, tkReturn, tkVar, tkPrint, tkTrue, tkFalse, tkNil

  Token* = object
    kind*: TokenType
    lexeme*: string
    line*: int
    col*: int
    numberVal*: float64
    strVal*: string
    errorMsg*: string

  Lexer* = object
    source: string
    start: int
    current: int
    line: int
    lineStart: int

proc initLexer*(source: string): Lexer =
  Lexer(
    source: source,
    start: 0,
    current: 0,
    line: 1,
    lineStart: 0
  )

proc isAtEnd(lexer: Lexer): bool =
  lexer.current >= lexer.source.len

proc advance(lexer: var Lexer): char =
  result = lexer.source[lexer.current]
  inc lexer.current

proc peek(lexer: Lexer): char =
  if lexer.isAtEnd(): '\0'
  else: lexer.source[lexer.current]

proc peekNext(lexer: Lexer): char =
  if lexer.current + 1 >= lexer.source.len: '\0'
  else: lexer.source[lexer.current + 1]

proc match(lexer: var Lexer, expected: char): bool =
  if lexer.isAtEnd(): return false
  if lexer.source[lexer.current] != expected: return false
  inc lexer.current
  return true

proc makeToken(lexer: Lexer, kind: TokenType): Token =
  let lexeme = lexer.source[lexer.start ..< lexer.current]
  Token(
    kind: kind,
    lexeme: lexeme,
    line: lexer.line,
    col: lexer.start - lexer.lineStart + 1
  )

proc makeErrorToken(lexer: Lexer, message: string): Token =
  Token(
    kind: tkError,
    lexeme: lexer.source[lexer.start ..< lexer.current],
    line: lexer.line,
    col: lexer.start - lexer.lineStart + 1,
    errorMsg: message
  )

proc isDigit(c: char): bool =
  c >= '0' and c <= '9'

proc isAlpha(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'

proc isAlphaNumeric(c: char): bool =
  isAlpha(c) or isDigit(c)

proc checkKeyword(lexer: Lexer, start, length: int, rest: string, kind: TokenType): TokenType =
  if lexer.current - lexer.start == start + length and
     lexer.source[lexer.start + start ..< lexer.start + start + length] == rest:
    return kind
  return tkIdentifier

proc identifierKind(lexer: Lexer): TokenType =
  let c = lexer.source[lexer.start]
  case c
  of 'e': return lexer.checkKeyword(1, 3, "lse", tkElse)
  of 'f':
    if lexer.current - lexer.start > 1:
      case lexer.source[lexer.start + 1]
      of 'a': return lexer.checkKeyword(2, 3, "lse", tkFalse)
      of 'n': return lexer.checkKeyword(2, 0, "", tkFn)
      else: discard
  of 'i': return lexer.checkKeyword(1, 1, "f", tkIf)
  of 'n': return lexer.checkKeyword(1, 2, "il", tkNil)
  of 'p': return lexer.checkKeyword(1, 4, "rint", tkPrint)
  of 'r': return lexer.checkKeyword(1, 5, "eturn", tkReturn)
  of 't': return lexer.checkKeyword(1, 3, "rue", tkTrue)
  of 'v': return lexer.checkKeyword(1, 2, "ar", tkVar)
  of 'w': return lexer.checkKeyword(1, 4, "hile", tkWhile)
  else: discard
  return tkIdentifier

proc stringToken(lexer: var Lexer): Token =
  var val = ""
  while not lexer.isAtEnd() and lexer.peek() != '"':
    if lexer.peek() == '\n':
      inc lexer.line
      lexer.lineStart = lexer.current + 1
    if lexer.peek() == '\\':
      discard lexer.advance()
      if lexer.isAtEnd():
        return lexer.makeErrorToken("Unterminated string escape.")
      let esc = lexer.advance()
      case esc
      of 'n': val.add('\n')
      of 't': val.add('\t')
      of 'r': val.add('\r')
      of '\\': val.add('\\')
      of '"': val.add('"')
      else: val.add(esc)
    else:
      val.add(lexer.advance())

  if lexer.isAtEnd():
    return lexer.makeErrorToken("Unterminated string.")

  # Consume closing "
  discard lexer.advance()
  var tok = lexer.makeToken(tkString)
  tok.strVal = val
  return tok

proc parseFloatSimple(s: string): float64 =
  try:
    return strutils.parseFloat(s)
  except ValueError:
    return 0.0

proc numberToken(lexer: var Lexer): Token =
  while isDigit(lexer.peek()):
    discard lexer.advance()

  # Look for fractional part
  if lexer.peek() == '.' and isDigit(lexer.peekNext()):
    discard lexer.advance() # consume '.'
    while isDigit(lexer.peek()):
      discard lexer.advance()

  var tok = lexer.makeToken(tkNumber)
  tok.numberVal = parseFloatSimple(tok.lexeme)
  return tok

proc identifierToken(lexer: var Lexer): Token =
  while isAlphaNumeric(lexer.peek()):
    discard lexer.advance()
  return lexer.makeToken(lexer.identifierKind())

proc skipWhitespaceAndComments(lexer: var Lexer) =
  while true:
    if lexer.isAtEnd(): break
    let c = lexer.peek()
    case c
    of ' ', '\r', '\t':
      discard lexer.advance()
    of '\n':
      inc lexer.line
      discard lexer.advance()
      lexer.lineStart = lexer.current
    of '/':
      if lexer.peekNext() == '/':
        # A line comment
        while lexer.peek() != '\n' and not lexer.isAtEnd():
          discard lexer.advance()
      else:
        break
    else:
      break

proc nextToken*(lexer: var Lexer): Token =
  lexer.skipWhitespaceAndComments()
  lexer.start = lexer.current

  if lexer.isAtEnd():
    return lexer.makeToken(tkEof)

  let c = lexer.advance()

  if isAlpha(c):
    return lexer.identifierToken()
  if isDigit(c):
    return lexer.numberToken()

  case c
  of '(': return lexer.makeToken(tkLParen)
  of ')': return lexer.makeToken(tkRParen)
  of '{': return lexer.makeToken(tkLBrace)
  of '}': return lexer.makeToken(tkRBrace)
  of ',': return lexer.makeToken(tkComma)
  of ';': return lexer.makeToken(tkSemicolon)
  of '+': return lexer.makeToken(tkPlus)
  of '-': return lexer.makeToken(tkMinus)
  of '*': return lexer.makeToken(tkStar)
  of '/': return lexer.makeToken(tkSlash)
  of '!':
    if lexer.match('='): return lexer.makeToken(tkNotEq)
    else: return lexer.makeToken(tkBang)
  of '=':
    if lexer.match('='): return lexer.makeToken(tkEq)
    else: return lexer.makeToken(tkAssign)
  of '<':
    if lexer.match('='): return lexer.makeToken(tkLtEq)
    else: return lexer.makeToken(tkLt)
  of '>':
    if lexer.match('='): return lexer.makeToken(tkGtEq)
    else: return lexer.makeToken(tkGt)
  of '"':
    return lexer.stringToken()
  else:
    return lexer.makeErrorToken("Unexpected character: " & $c)
