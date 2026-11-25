// RUN: %eopt %s --remove-unnecessary-enzyme-ops | FileCheck %s

func.func private @read_tensor() -> tensor<64xf64>
func.func private @use_scalars(f64, f64)

// The reverse needs two different elements of one non-recomputable tensor.
// Saving both elements is cheaper than saving their common 512-byte input.
func.func @two_elements(%cond: i1) {
  %i = arith.constant 0 : index
  %j = arith.constant 1 : index
  %ac = "enzyme.init"() : () -> !enzyme.Cache<f64>
  %bc = "enzyme.init"() : () -> !enzyme.Cache<f64>
  scf.if %cond {
    %t = func.call @read_tensor() : () -> tensor<64xf64>
    %a = tensor.extract %t[%i] : tensor<64xf64>
    %b = tensor.extract %t[%j] : tensor<64xf64>
    "enzyme.push"(%ac, %a) : (!enzyme.Cache<f64>, f64) -> ()
    "enzyme.push"(%bc, %b) : (!enzyme.Cache<f64>, f64) -> ()
  }
  scf.if %cond {
    %a = "enzyme.pop"(%ac) : (!enzyme.Cache<f64>) -> f64
    %b = "enzyme.pop"(%bc) : (!enzyme.Cache<f64>) -> f64
    func.call @use_scalars(%a, %b) : (f64, f64) -> ()
  }
  return
}

// CHECK-LABEL: func.func @two_elements(
// CHECK: scf.if {{.*}} -> (f64, f64) {
// CHECK: tensor.extract
// CHECK: tensor.extract
// CHECK: scf.yield {{.*}} : f64, f64

func.func private @read_matrix() -> tensor<2x2xf32>
func.func private @use_vector(tensor<64xf32>)

// The lower-rank gather result has sixteen times as many elements. Neither
// the cut nor a later rank-based refinement should save it in place of %t.
func.func @rank_reducing_gather(%cond: i1, %indices: tensor<64x2xindex>) {
  %cache = "enzyme.init"() : () -> !enzyme.Cache<tensor<64xf32>>
  scf.if %cond {
    %t = func.call @read_matrix() : () -> tensor<2x2xf32>
    %g = tensor.gather %t[%indices] gather_dims([0, 1]) :
        (tensor<2x2xf32>, tensor<64x2xindex>) -> tensor<64xf32>
    "enzyme.push"(%cache, %g) : (!enzyme.Cache<tensor<64xf32>>, tensor<64xf32>) -> ()
  }
  scf.if %cond {
    %g = "enzyme.pop"(%cache) : (!enzyme.Cache<tensor<64xf32>>) -> tensor<64xf32>
    func.call @use_vector(%g) : (tensor<64xf32>) -> ()
  }
  return
}

// CHECK-LABEL: func.func @rank_reducing_gather(
// CHECK: %[[SAVED:[^ ]+]] = scf.if {{.*}} -> (tensor<2x2xf32>) {
// CHECK: tensor.gather %[[SAVED]]

func.func private @read_unranked() -> tensor<*xf64>
func.func private @read_large() -> tensor<1152921504606846976xf64>

// Intermediate sizes may be unknown or overflow the size estimate. Both
// values can still be cut at their statically sized scalar result.
func.func @unknown_sizes(%cond: i1, %index: index) {
  %ac = "enzyme.init"() : () -> !enzyme.Cache<f64>
  %bc = "enzyme.init"() : () -> !enzyme.Cache<f64>
  scf.if %cond {
    %u = func.call @read_unranked() : () -> tensor<*xf64>
    %d = tensor.cast %u : tensor<*xf64> to tensor<?xf64>
    %a = tensor.extract %d[%index] : tensor<?xf64>
    %t = func.call @read_large() : () -> tensor<1152921504606846976xf64>
    %b = tensor.extract %t[%index] : tensor<1152921504606846976xf64>
    "enzyme.push"(%ac, %a) : (!enzyme.Cache<f64>, f64) -> ()
    "enzyme.push"(%bc, %b) : (!enzyme.Cache<f64>, f64) -> ()
  }
  scf.if %cond {
    %a = "enzyme.pop"(%ac) : (!enzyme.Cache<f64>) -> f64
    %b = "enzyme.pop"(%bc) : (!enzyme.Cache<f64>) -> f64
    func.call @use_scalars(%a, %b) : (f64, f64) -> ()
  }
  return
}

// CHECK-LABEL: func.func @unknown_sizes(
// CHECK: scf.if {{.*}} -> (f64, f64) {

func.func private @read_empty() -> tensor<0xf32>
func.func private @use_empty(tensor<0xf32>)

// A zero-byte split edge may already be saturated before the first search.
func.func @empty_cache(%cond: i1) {
  %cache = "enzyme.init"() : () -> !enzyme.Cache<tensor<0xf32>>
  scf.if %cond {
    %t = func.call @read_empty() : () -> tensor<0xf32>
    "enzyme.push"(%cache, %t) : (!enzyme.Cache<tensor<0xf32>>, tensor<0xf32>) -> ()
  }
  scf.if %cond {
    %t = "enzyme.pop"(%cache) : (!enzyme.Cache<tensor<0xf32>>) -> tensor<0xf32>
    func.call @use_empty(%t) : (tensor<0xf32>) -> ()
  }
  return
}
// CHECK-LABEL: func.func @empty_cache(
// CHECK: scf.if {{.*}} -> (tensor<0xf32>)

func.func private @read_extended() -> tensor<4xf80>
func.func private @use_extended(tensor<4xf80>)

// The element type has no Enzyme size model. Keep the direct cache.
func.func @unknown_budget(%cond: i1) {
  %cache = "enzyme.init"() : () -> !enzyme.Cache<tensor<4xf80>>
  scf.if %cond {
    %v = func.call @read_extended() : () -> tensor<4xf80>
    "enzyme.push"(%cache, %v) : (!enzyme.Cache<tensor<4xf80>>, tensor<4xf80>) -> ()
  }
  scf.if %cond {
    %v = "enzyme.pop"(%cache) : (!enzyme.Cache<tensor<4xf80>>) -> tensor<4xf80>
    func.call @use_extended(%v) : (tensor<4xf80>) -> ()
  }
  return
}
// CHECK-LABEL: func.func @unknown_budget(
// CHECK: scf.if {{.*}} -> (tensor<4xf80>)
