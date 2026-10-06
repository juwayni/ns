import api, vm

proc traceGlobals() =
  var vm = initVM()
  let src = """
  var a = 15;
  print a;
  """
  let res = runScriptEx(src, vm)
  echo "res: ", res, " output: ", vm.output

traceGlobals()
