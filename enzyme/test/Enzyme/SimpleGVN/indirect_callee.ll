; RUN: %opt < %s %newLoadEnzyme -passes="simple-gvn" -S | FileCheck %s

; The callee is a use of a pointer, but not a parameter of the call.
define double @indirect(ptr %fn, double %x) {
  %result = call double %fn(double %x)
  ret double %result
}
; CHECK-LABEL: define double @indirect(
; CHECK: %result = call double %fn(double %x)
; CHECK: ret double %result

; Bundle operands also cannot be classified using parameter attributes.
declare void @external()
define double @bundle(ptr %p) {
  store double 1.0, ptr %p
  call void @external() [ "unknown"(ptr %p) ]
  %result = load double, ptr %p
  ret double %result
}
; CHECK-LABEL: define double @bundle(
; CHECK: call void @external() [ "unknown"(ptr %p) ]
; CHECK: %result = load double, ptr %p
; CHECK: ret double %result
