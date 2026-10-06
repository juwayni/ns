import vm, compiler

proc testVMClosuresAndUpvalues() =
  var vm = initVM()

  # Test 1: Lexical Closures / Upvalues (makeMultiplier)
  let srcClosure = """
  fn makeMultiplier(factor) {
    fn mul(x) {
      return x * factor;
    }
    return mul;
  }
  var double = makeMultiplier(2);
  var triple = makeMultiplier(3);
  print double(5);
  print triple(5);
  """
  let res1 = vm.interpret(srcClosure)
  assert res1 == irOk
  assert vm.output == "10.0\n15.0\n"

  # Test 2: Recursive Fibonacci
  var vm2 = initVM()
  let srcFib = """
  fn fib(n) {
    if (n <= 1) {
      return n;
    }
    return fib(n - 1) + fib(n - 2);
  }
  print fib(10);
  """
  let res2 = vm2.interpret(srcFib)
  assert res2 == irOk
  assert vm2.output == "55.0\n"

  freeVM(vm)
  freeVM(vm2)
  echo "VM Closures & Upvalues verified successfully!"

testVMClosuresAndUpvalues()
