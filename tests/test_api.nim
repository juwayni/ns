import api, vm, compiler

proc testHostAPI() =
  var vm = initVM()
  vm.registerMathModule()

  # Test 1: Calling Nim Native Math Bridge from script
  let src = """
  var s = sin(0.0);
  var sq = sqrt(16.0);
  var a = abs(-42.5);
  print sq;
  print a;
  """
  let res = runScriptEx(src, vm)
  assert res == irOk
  assert vm.output == "4.0\n42.5\n"

  # Test 2: Bidirectional callFunction from Nim host into script
  let scriptFn = """
  fn multiply(x, y) {
    return x * y;
  }
  """
  discard runScriptEx(scriptFn, vm)

  let resultVal = vm.callFunction("multiply", [valNum(6.0), valNum(7.0)])
  assert isNum(resultVal) and asNum(resultVal) == 42.0

  echo "Host API and Native Nim Bridge tests passed successfully!"

testHostAPI()
