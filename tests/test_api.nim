import api, vm, compiler

proc customFFIMath(a, b: float64): float64 {.exportc: "customFFIMath", dynlib, cdecl.} =
  return a * 2.0 + b

proc testHostAPIAutoBinderAndFFI() =
  var vm = initVM()
  vm.loadStdlib()

  # Test 1: Auto-bound Math, OS, and StrUtils procs called directly from script
  let src = """
  var sq = sqrt(16.0);
  var up = toUpperAscii("hello script");
  print sq;
  print up;
  """
  let res1 = runScriptEx(src, vm)
  assert res1 == irOk
  assert vm.output == "4.0\nHELLO SCRIPT\n"

  # Test 2: Dynamic FFI symbol resolution from current executable address space
  let ffiSrc = """
  var sym = ffiLoad("customFFIMath");
  var res = ffiCall(sym, 10.0, 5.0);
  print res;
  """
  var vmFFI = initVM()
  vmFFI.loadStdlib()
  let res2 = runScriptEx(ffiSrc, vmFFI)
  assert res2 == irOk
  assert vmFFI.output == "25.0\n"

  # Test 3: Bidirectional callFunction from Nim host into script
  let scriptFn = """
  fn multiply(x, y) {
    return x * y;
  }
  """
  discard runScriptEx(scriptFn, vm)

  let resultVal = vm.callFunction("multiply", [valNum(6.0), valNum(7.0)])
  assert isNum(resultVal) and asNum(resultVal) == 42.0

  freeVM(vm)
  freeVM(vmFFI)
  echo "Host API Auto-Binder & Dynamic FFI tests passed successfully!"

testHostAPIAutoBinderAndFFI()
