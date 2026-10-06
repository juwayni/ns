import compiler, vm

proc testCompilerFixes() =
  var vm = initVM()

  # Test 1: Value Size & O(1) String Interning Pointer Equality
  assert sizeof(Value) == 8

  let str1 = internStringImpl(addr vm, "hello_world")
  let str2 = internStringImpl(addr vm, "hello_world")

  # Strict string interning guarantees pointer equality
  assert asObj(str1) == asObj(str2)
  assert valuesEqual(str1, str2)

  # Test 2: Flexible Array Single Allocation ObjString Memory Layout
  let strObj = asObjString(str1)
  assert strObj.length == 11
  assert getString(strObj) == "hello_world"

  # Test 3: Lexical Closures Compilation
  let src = """
  fn makeAdder(x) {
    fn add(y) {
      return x + y;
    }
    return add;
  }
  """
  let fnScript = compile(src, addr vm, internStringImpl, newFunctionImpl)
  assert fnScript != nil
  assert vm.objects != nil

  freeVM(vm)
  assert vm.objects == nil, "freeVM must clean up all tracked heap allocations!"

  echo "Compiler & ObjString memory layout verified successfully!"

testCompilerFixes()
