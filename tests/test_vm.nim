import vm, compiler

proc testVM() =
  var vm = initVM()
  let src = """
  var sum = 0;
  var i = 1;
  while (i <= 10) {
    sum = sum + i;
    i = i + 1;
  }
  print sum;
  """
  let res = vm.interpret(src)
  assert res == irOk, "VM execution failed!"
  assert vm.globals["sum"].kind == vkNumber and vm.globals["sum"].numberVal == 55.0
  assert vm.output == "55.0\n"

  echo "VM tests passed successfully!"

testVM()
