import api, lexer, compiler, vm

proc testEndToEnd() =
  echo "=== Running Complete End-to-End Language Engine Tests ==="

  # Test 1: Arithmetic & Fast Local Variables
  let script1 = """
  var a = 15;
  var b = 4;
  {
    var localC = a + b * 2;
    print localC; // 23
  }
  """
  var vm1 = initVM()
  let res1 = runScriptEx(script1, vm1)
  assert res1 == irOk
  assert vm1.output == "23.0\n"

  # Test 2: Control Flow & Short-circuit Logic
  let script2 = """
  var count = 0;
  var i = 0;
  while (i < 5) {
    if (i == 2 or false) {
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

  # Test 3: String Interning & O(1) Equality
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

  # Test 4: First-class Functions & Recursion
  let script4 = """
  fn fib(n) {
    if (n <= 1) {
      return n;
    }
    return fib(n - 1) + fib(n - 2);
  }
  print fib(10);
  """
  var vm4 = initVM()
  let res4 = runScriptEx(script4, vm4)
  assert res4 == irOk
  assert vm4.output == "55.0\n"

  # Test 5: Native Nim Stdlib Bridge
  var vm5 = initVM()
  vm5.registerMathModule()
  let script5 = """
  var sq = sqrt(144.0);
  print sq;
  """
  let res5 = runScriptEx(script5, vm5)
  assert res5 == irOk
  assert vm5.output == "12.0\n"

  # Test 6: Runtime Error handling
  let script6 = "print nonExistentVar;"
  var vm6 = initVM()
  let res6 = runScriptEx(script6, vm6)
  assert res6 == irRuntimeError

  echo "=== All End-to-End Tests Passed Successfully! ==="

testEndToEnd()
