import api, vm, compiler
import std/[times, osproc, strutils, os]

proc runLuaBench(luaCode: string): float64 =
  let tmpFile = "temp_bench.lua"
  let wrappedCode = """
  local start = os.clock()
  """ & luaCode & """
  local elapsed = os.clock() - start
  print(string.format("%.6f", elapsed))
  """
  writeFile(tmpFile, wrappedCode)
  let output = execProcess("lua5.4 " & tmpFile)
  removeFile(tmpFile)
  try:
    return parseFloat(strip(output))
  except ValueError:
    return 0.0

proc runNimBench(scriptCode: string): float64 =
  var vm = initVM()
  let scriptFn = compile(scriptCode, addr vm, internStringImpl, newFunctionImpl)
  let scriptClosure = vm.newClosure(scriptFn)
  vm.push(valObj(scriptClosure))
  discard vm.call(scriptClosure, 0)

  let start = cpuTime()
  discard vm.run()
  let elapsed = cpuTime() - start
  freeVM(vm)
  return elapsed

proc runPerformanceComparison() =
  echo "================================────────────────────────────────"
  echo "          PERFORMANCE BENCHMARK: NIM ENGINE VS LUA 5.4          "
  echo "================================────────────────────────────────"

  # Benchmark 1: Numeric While Loop Reduction (10,000,000 iterations)
  let nimLoop = """
  var sum = 0;
  var i = 0;
  while (i < 10000000) {
    sum = sum + i;
    i = i + 1;
  }
  """
  let luaLoop = """
  local sum = 0
  local i = 0
  while i < 10000000 do
    sum = sum + i
    i = i + 1
  end
  """
  let tNimLoop = runNimBench(nimLoop)
  let tLuaLoop = runLuaBench(luaLoop)
  echo "1. Loop Reduction (10M):"
  echo "   Nim Engine: ", formatFloat(tNimLoop, ffDecimal, 4), "s | Lua 5.4: ", formatFloat(tLuaLoop, ffDecimal, 4), "s"

  # Benchmark 2: Recursive Fibonacci (fib(28))
  let nimFib = """
  fn fib(n) {
    if (n <= 1) {
      return n;
    }
    return fib(n - 1) + fib(n - 2);
  }
  var res = fib(28);
  """
  let luaFib = """
  local function fib(n)
    if n <= 1 then
      return n
    end
    return fib(n - 1) + fib(n - 2)
  end
  local res = fib(28)
  """
  let tNimFib = runNimBench(nimFib)
  let tLuaFib = runLuaBench(luaFib)
  echo "2. Recursive Fibonacci (fib(28)):"
  echo "   Nim Engine: ", formatFloat(tNimFib, ffDecimal, 4), "s | Lua 5.4: ", formatFloat(tLuaFib, ffDecimal, 4), "s"

  # Benchmark 3: Lexical Closures Invocation
  let nimClosure = """
  fn makeAdder(x) {
    fn add(y) {
      return x + y;
    }
    return add;
  }
  var adder = makeAdder(5);
  var sum = 0;
  var i = 0;
  while (i < 1000000) {
    sum = sum + adder(i);
    i = i + 1;
  }
  """
  let luaClosure = """
  local function makeAdder(x)
    local function add(y)
      return x + y
    end
    return add
  end
  local adder = makeAdder(5)
  local sum = 0
  local i = 0
  while i < 1000000 do
    sum = sum + adder(i)
    i = i + 1
  end
  """
  let tNimClosure = runNimBench(nimClosure)
  let tLuaClosure = runLuaBench(luaClosure)
  echo "3. Lexical Closures (1M calls):"
  echo "   Nim Engine: ", formatFloat(tNimClosure, ffDecimal, 4), "s | Lua 5.4: ", formatFloat(tLuaClosure, ffDecimal, 4), "s"

  echo "================================────────────────────────────────"

runPerformanceComparison()
