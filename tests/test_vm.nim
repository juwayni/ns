import vm, compiler

proc testVMUpgrades() =
  var vm = initVM()

  # Test 1: Functions, Recursion, and Local Scope
  let src = """
  fn fib(n) {
    if (n <= 1) {
      return n;
    }
    return fib(n - 1) + fib(n - 2);
  }
  print fib(10);
  """
  let res = vm.interpret(src)
  assert res == irOk, "VM execution failed for recursive function!"
  assert vm.output == "55.0\n"

  echo "VM upgrade unit tests passed successfully!"

testVMUpgrades()
