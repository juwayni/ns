import compiler

proc testCompilerUpgrades() =
  # Test 1: NaN-Tagged Value Size
  assert sizeof(Value) == 8, "Value size must be exactly 8 bytes!"

  # Test 2: Encoding/Decoding Values
  let numVal = valNum(3.14159)
  assert isNum(numVal) and asNum(numVal) == 3.14159

  let nilVal = valNil()
  assert isNil(nilVal) and not isNum(nilVal)

  let trueVal = valBool(true)
  assert isBool(trueVal) and asBool(trueVal) == true

  let strObj = newObjString("hello")
  let strVal = valObj(strObj)
  assert isObj(strVal) and isObjKind(strVal, objString)
  assert asObjString(strVal).strVal == "hello"

  # Test 3: Compiler function compilation with local variables and short-circuiting
  let src = """
  fn add(a, b) {
    var sum = a + b;
    if (sum > 10 and true) {
      return sum;
    }
    return 0;
  }
  """
  let fnScript = compile(src)
  assert fnScript != nil, "Script compilation failed!"
  assert fnScript.chunk.code.len > 0, "Script bytecode empty!"

  echo "Compiler upgrade unit tests passed successfully!"

testCompilerUpgrades()
