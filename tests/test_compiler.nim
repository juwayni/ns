import compiler, vm

proc testCompilerFixes() =
  var vm = initVM()

  # Test 1: Value Size & O(1) String Interning Equality
  assert sizeof(Value) == 8

  let str1 = internStringImpl(addr vm, "hello_world")
  let str2 = internStringImpl(addr vm, "hello_world")

  # Strict string interning guarantees pointer equality
  assert asObj(str1) == asObj(str2)
  assert valuesEqual(str1, str2)

  # Test 2: Compile script passing pointer lexer and VM object tracking
  let src = """
  fn outer() {
    fn inner(x) {
      return x + 1;
    }
    return inner(10);
  }
  """
  let fnScript = compile(src, addr vm, internStringImpl, newFunctionImpl)
  assert fnScript != nil
  assert vm.objects.len > 0, "Compiler must register all string and function allocations into vm.objects!"

  freeVM(vm)
  assert vm.objects.len == 0, "freeVM must clean up all tracked heap allocations!"

  echo "Compiler fixes verified successfully!"

testCompilerFixes()
