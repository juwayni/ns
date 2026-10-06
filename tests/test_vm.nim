import vm, compiler

proc testVMClosuresAndArrays() =
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

  # Test 2: Packed Array Literals & Subscripting
  var vm2 = initVM()
  let srcArray = """
  var arr = [10, 20, 30];
  print arr[1];
  arr[1] = 99;
  print arr[1];
  """
  let res2 = vm2.interpret(srcArray)
  assert res2 == irOk
  assert vm2.output == "20.0\n99.0\n"

  freeVM(vm)
  freeVM(vm2)
  echo "VM Closures, Upvalues & Packed Arrays verified successfully!"

testVMClosuresAndArrays()
