; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme -enzyme-runtime-error -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme" -enzyme-runtime-error -S | FileCheck %s

; A function without a definition is differentiated once and its derivative
; cached. The first call that requests it gets the error at the call; every
; call must also get it from the cached derivative's body, rather than reach
; a bare unreachable there.

declare double @g(double)

define double @f(double %x, double %y) {
entry:
  %a = call double @g(double %x)
  %b = call double @g(double %y)
  %s = fadd double %a, %b
  ret double %s
}

declare double @__enzyme_fwddiff(...)

define double @df(double %x, double %y) {
entry:
  %r = call double (...) @__enzyme_fwddiff(double (double, double)* @f, double %x, double 1.0, double %y, double 1.0)
  ret double %r
}

; CHECK: define internal {{.*}} @fwddiffef(double %x, double %"x'", double %y, double %"y'")
; CHECK: call i32 @puts(
; CHECK-NEXT: call void @exit(i32 1)
; CHECK-NEXT: call {{.*}} @fwddiffeg(
; CHECK-NOT: @puts
; CHECK: call {{.*}} @fwddiffeg(

; CHECK: define internal {{.*}} @fwddiffeg(
; CHECK-NEXT: entry:
; CHECK-NEXT:   call i32 @puts(
; CHECK-NEXT:   call void @exit(i32 1)
; CHECK-NEXT:   unreachable
