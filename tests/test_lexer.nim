import lexer

proc testLexer() =
  let src = """
  var x = 42.5;
  if (x >= 10 and true) {
    print "hello\nworld";
  } else {
    return nil;
  }
  fn while false != == <= < >
  """
  var lex = initLexer(src)
  var tokens: seq[Token] = @[]
  while true:
    let tok = lex.nextToken()
    tokens.add(tok)
    if tok.kind == tkEof or tok.kind == tkError:
      break

  assert tokens[0].kind == tkVar
  assert tokens[1].kind == tkIdentifier and tokens[1].lexeme == "x"
  assert tokens[2].kind == tkAssign
  assert tokens[3].kind == tkNumber and tokens[3].numberVal == 42.5
  assert tokens[4].kind == tkSemicolon

  assert tokens[5].kind == tkIf
  assert tokens[6].kind == tkLParen
  assert tokens[7].kind == tkIdentifier and tokens[7].lexeme == "x"
  assert tokens[8].kind == tkGtEq
  assert tokens[9].kind == tkNumber and tokens[9].numberVal == 10.0
  assert tokens[10].kind == tkIdentifier and tokens[10].lexeme == "and"
  assert tokens[11].kind == tkTrue
  assert tokens[12].kind == tkRParen
  assert tokens[13].kind == tkLBrace

  assert tokens[14].kind == tkPrint
  assert tokens[15].kind == tkString and tokens[15].strVal == "hello\nworld"
  assert tokens[16].kind == tkSemicolon
  assert tokens[17].kind == tkRBrace

  assert tokens[18].kind == tkElse
  assert tokens[19].kind == tkLBrace
  assert tokens[20].kind == tkReturn
  assert tokens[21].kind == tkNil
  assert tokens[22].kind == tkSemicolon
  assert tokens[23].kind == tkRBrace

  assert tokens[24].kind == tkFn
  assert tokens[25].kind == tkWhile
  assert tokens[26].kind == tkFalse
  assert tokens[27].kind == tkNotEq
  assert tokens[28].kind == tkEq
  assert tokens[29].kind == tkLtEq
  assert tokens[30].kind == tkLt
  assert tokens[31].kind == tkGt
  assert tokens[32].kind == tkEof

  echo "Lexer tests passed successfully!"

testLexer()
