import api, vm, compiler

proc testHostAPIAutoBinder() =
  var vm = initVM()
  vm.loadStdlib()

  # Test 1: Auto-bound Math, OS, and StrUtils procs called directly from script
  let src = """
  var sq = sqrt(16.0);
  var up = toUpperAscii("hello script");
  print sq;
  print up;
  """
  let res = runScriptEx(src, vm)
  assert res == irOk
  assert vm.output == "4.0\nHELLO SCRIPT\n"

  # Test 2: Bidirectional callFunction from Nim host into script
  let scriptFn = """
  fn multiply(x, y) {
    return x * y;
  }
  """
  discard runScriptEx(scriptFn, vm)

  let resultVal = vm.callFunction("multiply", [valNum(6.0), valNum(7.0)])
  assert isNum(resultVal) and asNum(resultVal) == 42.0

  freeVM(vm)
  echo "Host API Auto-Binder tests passed successfully!"

testHostAPIAutoBinder()
