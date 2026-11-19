// RUN: %eopt %s --enzyme --inline --canonicalize --remove-unnecessary-enzyme-ops --canonicalize --symbol-dce | FileCheck %s
//
// The authored derivative of the square is 3*x. Differentiating it again
// must use the authored reverse body in both forward and reverse mode.
module {
  func.func private @sq(%x: f64) -> f64 attributes {enzyme.custom_rule = @sq_rule} {
    %y = arith.mulf %x, %x : f64
    return %y : f64
  }

  enzyme.custom_reverse_rule @sq_rule {
    %cx = "enzyme.init"() : () -> !enzyme.Cache<f64>
    enzyme.custom_reverse_rule.augmented_primal (%x: f64) -> f64 {
      "enzyme.push"(%cx, %x) : (!enzyme.Cache<f64>, f64) -> ()
      %y = arith.mulf %x, %x : f64
      enzyme.yield %y : f64
    }
    enzyme.custom_reverse_rule.reverse (%ybar: f64) -> f64 {
      %x = "enzyme.pop"(%cx) : (!enzyme.Cache<f64>) -> f64
      %three = arith.constant 3.0 : f64
      %t = arith.mulf %three, %x : f64
      %xbar = arith.mulf %ybar, %t : f64
      enzyme.yield %xbar : f64
    }
    enzyme.yield
  } <{
    activity = [#enzyme.activity<enzyme_active>],
    ret_activity = [#enzyme.activity<enzyme_active>],
    function_type = (f64) -> f64
  }>

  func.func private @outer(%x: f64) -> f64 {
    %y = func.call @sq(%x) : (f64) -> f64
    return %y : f64
  }
  func.func private @gradient(%x: f64) -> f64 {
    %one = arith.constant 1.0 : f64
    %dx = enzyme.autodiff @outer(%x, %one) <{
      activity = [#enzyme.activity<enzyme_active>],
      ret_activity = [#enzyme.activity<enzyme_activenoneed>]
    }> : (f64, f64) -> f64
    return %dx : f64
  }
  func.func @main() -> (f64, f64, f64) {
    %x = arith.constant 2.0 : f64
    %dx = arith.constant 5.0 : f64
    %dy = arith.constant 7.0 : f64
    %g = func.call @gradient(%x) : (f64) -> f64
    %f = enzyme.fwddiff @gradient(%x, %dx) <{
      activity = [#enzyme.activity<enzyme_dup>],
      ret_activity = [#enzyme.activity<enzyme_dupnoneed>]
    }> : (f64, f64) -> f64
    %r = enzyme.autodiff @gradient(%x, %dy) <{
      activity = [#enzyme.activity<enzyme_active>],
      ret_activity = [#enzyme.activity<enzyme_activenoneed>]
    }> : (f64, f64) -> f64
    return %g, %f, %r : f64, f64, f64
  }
}
// CHECK-LABEL: func.func @main()
// CHECK-DAG: %[[GRAD:.*]] = arith.constant 6.000000e+00 : f64
// CHECK-DAG: %[[FORWARD:.*]] = arith.constant 1.500000e+01 : f64
// CHECK-DAG: %[[REVERSE:.*]] = arith.constant 2.100000e+01 : f64
// CHECK: return %[[GRAD]], %[[FORWARD]], %[[REVERSE]]
