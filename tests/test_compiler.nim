import compiler

proc testCompiler() =
  let source = """
  var a = 10;
  var b = 20;
  var c = a + b * 3;
  if (c > 50) {
    print c;
  } else {
    print "lower";
  }
  """
  var chunk: Chunk
  let success = compile(source, chunk)
  assert success, "Compilation failed!"
  assert chunk.code.len > 0, "Bytecode stream should not be empty!"
  assert chunk.constants.len > 0, "Constant pool should not be empty!"

  echo "Compiler test passed! Code length: ", chunk.code.len, " Constants count: ", chunk.constants.len

testCompiler()
