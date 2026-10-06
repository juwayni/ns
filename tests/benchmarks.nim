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
  if scriptFn == nil: return 0.0
  let scriptClosure = vm.newClosure(scriptFn)
  vm.push(valObj(scriptClosure))
  discard vm.call(scriptClosure, 0)

  let start = cpuTime()
  discard vm.run()
  let elapsed = cpuTime() - start
  freeVM(vm)
  return elapsed

proc runAllBenchmarks*() =
  echo "================================─────────────────────────────────────────"
  echo "        HONEST BENCHMARK COMPARISON: NIM SCRIPT ENGINE VS LUA 5.4        "
  echo "================================─────────────────────────────────────────"

  # 1. Loop Reduction (10M)
  let nim1 = "var sum = 0; var i = 0; while (i < 10000000) { sum = sum + i; i = i + 1; }"
  let lua1 = "local sum = 0; local i = 0; while i < 10000000 do sum = sum + i; i = i + 1 end"
  let tNim1 = runNimBench(nim1); let tLua1 = runLuaBench(lua1)
  echo "01. Loop Reduction (10M iterations)   : Nim = ", formatFloat(tNim1, ffDecimal, 4), "s | Lua 5.4 = ", formatFloat(tLua1, ffDecimal, 4), "s"

  # 2. Recursive Fibonacci (fib(28))
  let nim2 = "fn fib(n) { if (n <= 1) { return n; } return fib(n - 1) + fib(n - 2); } var r = fib(28);"
  let lua2 = "local function fib(n) if n <= 1 then return n end return fib(n - 1) + fib(n - 2) end local r = fib(28)"
  let tNim2 = runNimBench(nim2); let tLua2 = runLuaBench(lua2)
  echo "02. Recursive Fibonacci (fib(28))     : Nim = ", formatFloat(tNim2, ffDecimal, 4), "s | Lua 5.4 = ", formatFloat(tLua2, ffDecimal, 4), "s"

  # 3. Lexical Closures (1M calls)
  let nim3 = "fn makeAdder(x) { fn add(y) { return x + y; } return add; } var adder = makeAdder(5); var sum = 0; var i = 0; while (i < 1000000) { sum = sum + adder(i); i = i + 1; }"
  let lua3 = "local function makeAdder(x) local function add(y) return x + y end return add end local adder = makeAdder(5) local sum = 0 local i = 0 while i < 1000000 do sum = sum + adder(i) i = i + 1 end"
  let tNim3 = runNimBench(nim3); let tLua3 = runLuaBench(lua3)
  echo "03. Lexical Closures (1M calls)        : Nim = ", formatFloat(tNim3, ffDecimal, 4), "s | Lua 5.4 = ", formatFloat(tLua3, ffDecimal, 4), "s"

  # 4. Packed Array Access (500K ops)
  let nim4 = "var arr = [0, 0, 0]; var i = 0; while (i < 500000) { arr[0] = i; arr[1] = arr[0] + 1; i = i + 1; }"
  let lua4 = "local arr = {0, 0, 0}; local i = 0; while i < 500000 do arr[1] = i; arr[2] = arr[1] + 1; i = i + 1 end"
  let tNim4 = runNimBench(nim4); let tLua4 = runLuaBench(lua4)
  echo "04. Packed Array Access (500K ops)     : Nim = ", formatFloat(tNim4, ffDecimal, 4), "s | Lua 5.4 = ", formatFloat(tLua4, ffDecimal, 4), "s"

  # 5. Nested Loops (1K x 1K)
  let nim5 = "var sum = 0; var i = 0; while (i < 1000) { var j = 0; while (j < 1000) { sum = sum + 1; j = j + 1; } i = i + 1; }"
  let lua5 = "local sum = 0; local i = 0; while i < 1000 do local j = 0; while j < 1000 do sum = sum + 1; j = j + 1 end i = i + 1 end"
  let tNim5 = runNimBench(nim5); let tLua5 = runLuaBench(lua5)
  echo "05. Nested Loops (1000 x 1000)         : Nim = ", formatFloat(tNim5, ffDecimal, 4), "s | Lua 5.4 = ", formatFloat(tLua5, ffDecimal, 4), "s"

  # 6. String Concatenation & Interning (50K ops)
  let nim6 = "var str = \"a\"; var i = 0; while (i < 50000) { str = str + \"b\"; i = i + 1; }"
  let lua6 = "local str = \"a\"; local i = 0; while i < 50000 do str = str .. \"b\"; i = i + 1 end"
  let tNim6 = runNimBench(nim6); let tLua6 = runLuaBench(lua6)
  echo "06. String Concatenation (50K ops)    : Nim = ", formatFloat(tNim6, ffDecimal, 4), "s | Lua 5.4 = ", formatFloat(tLua6, ffDecimal, 4), "s"

  # 7. Conditional Branching (5M ops)
  let nim7 = "var count = 0; var i = 0; while (i < 5000000) { if (i > 2500000 and true) { count = count + 2; } else { count = count + 1; } i = i + 1; }"
  let lua7 = "local count = 0; local i = 0; while i < 5000000 do if i > 2500000 and true then count = count + 2 else count = count + 1 end i = i + 1 end"
  let tNim7 = runNimBench(nim7); let tLua7 = runLuaBench(lua7)
  echo "07. Conditional Branching (5M ops)    : Nim = ", formatFloat(tNim7, ffDecimal, 4), "s | Lua 5.4 = ", formatFloat(tLua7, ffDecimal, 4), "s"

  # 8. Function Call Overhead (1M calls)
  let nim8 = "fn inc(x) { return x + 1; } var sum = 0; var i = 0; while (i < 1000000) { sum = inc(sum); i = i + 1; }"
  let lua8 = "local function inc(x) return x + 1 end local sum = 0; local i = 0; while i < 1000000 do sum = inc(sum); i = i + 1 end"
  let tNim8 = runNimBench(nim8); let tLua8 = runLuaBench(lua8)
  echo "08. Function Call Overhead (1M calls) : Nim = ", formatFloat(tNim8, ffDecimal, 4), "s | Lua 5.4 = ", formatFloat(tLua8, ffDecimal, 4), "s"

  # 9. Prime Checking Sieve (N=10,000)
  let nim9 = "var primes = 0; var n = 2; while (n < 10000) { var isP = true; var d = 2; while (d * d <= n) { if (n - (n / d) * d == 0) { isP = false; } d = d + 1; } if (isP) { primes = primes + 1; } n = n + 1; }"
  let lua9 = "local primes = 0; local n = 2; while n < 10000 do local isP = true; local d = 2; while d * d <= n do if n % d == 0 then isP = false end d = d + 1 end if isP then primes = primes + 1 end n = n + 1 end"
  let tNim9 = runNimBench(nim9); let tLua9 = runLuaBench(lua9)
  echo "09. Prime Checking Sieve (N=10K)       : Nim = ", formatFloat(tNim9, ffDecimal, 4), "s | Lua 5.4 = ", formatFloat(tLua9, ffDecimal, 4), "s"

  # 10. Global Variable Access (2M ops)
  let nim10 = "var g = 0; var i = 0; while (i < 2000000) { g = g + 1; i = i + 1; }"
  let lua10 = "g = 0; local i = 0; while i < 2000000 do g = g + 1; i = i + 1 end"
  let tNim10 = runNimBench(nim10); let tLua10 = runLuaBench(lua10)
  echo "10. Global Variable Access (2M ops)   : Nim = ", formatFloat(tNim10, ffDecimal, 4), "s | Lua 5.4 = ", formatFloat(tLua10, ffDecimal, 4), "s"

  echo "================================─────────────────────────────────────────"

runAllBenchmarks()
