import api, lexer, compiler, vm

proc testEndToEnd() =
  echo "=== Running End-to-End Language Engine Tests ==="

  # Test 1: Basic Arithmetic & Output
  let script1 = """
  var a = 15;
  var b = 4;
  print a + b * 2; // Should print 23
  """
  var vm1 = initVM()
  let res1 = runScriptEx(script1, vm1)
  assert res1 == irOk
  assert vm1.output == "23.0\n"

  # Test 2: Control Flow (If / Else & Loops)
  let script2 = """
  var count = 0;
  var i = 0;
  while (i < 5) {
    if (i == 2) {
      count = count + 10;
    } else {
      count = count + 1;
    }
    i = i + 1;
  }
  print count; // 1 + 1 + 10 + 1 + 1 = 14
  """
  var vm2 = initVM()
  let res2 = runScriptEx(script2, vm2)
  assert res2 == irOk
  assert vm2.output == "14.0\n"

  # Test 3: String Concatenation & Comparisons
  let script3 = """
  var greeting = "Hello, " + "World!";
  print greeting;
  var isSame = greeting == "Hello, World!";
  print isSame;
  """
  var vm3 = initVM()
  let res3 = runScriptEx(script3, vm3)
  assert res3 == irOk
  assert vm3.output == "Hello, World!\ntrue\n"

  # Test 4: Runtime Errors (Undefined Variable)
  let script4 = "print unassignedVar;"
  var vm4 = initVM()
  let res4 = runScriptEx(script4, vm4)
  assert res4 == irRuntimeError

  # Test 5: Convenience API `runScript`
  let res5 = runScript("var x = 10; print x;")
  assert res5 == irOk

  echo "=== All End-to-End Tests Passed Successfully! ==="

testEndToEnd()
