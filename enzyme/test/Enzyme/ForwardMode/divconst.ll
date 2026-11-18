; RUN: %opt < %s %defaultLoadEnzyme -passes="enzyme,function(instsimplify)" -enzyme-preopt=false -S | FileCheck %s
; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %defaultLoadEnzyme -passes="enzyme,default<O2>" -enzyme-preopt=false -S | %lli -; fi

; The forward derivative of x / y with only one operand active divides by y and
; never forms y * y, which underflows to zero for |y| < 1.5e-154, and its y term
; goes through y' / y, not through x / y, which may overflow where the tangent
; does not.

define double @tester(double %x, double %y) {
entry:
  %0 = fdiv double %x, %y
  ret double %0
}

define double @test_derivative_x(double %x, double %y) {
entry:
  %0 = tail call double (double (double, double)*, ...) @__enzyme_fwddiff(double (double, double)* nonnull @tester, double %x, double 1.0, metadata !"enzyme_const", double %y)
  ret double %0
}

define double @test_derivative_y(double %x, double %y) {
entry:
  %0 = tail call double (double (double, double)*, ...) @__enzyme_fwddiff(double (double, double)* nonnull @tester, metadata !"enzyme_const", double %x, double %y, double 1.0)
  ret double %0
}

declare double @__enzyme_fwddiff(double (double, double)*, ...)

define double @tangent(double %x, double %dx, double %y, double %dy) {
entry:
  %d = call double (double (double, double)*, ...) @__enzyme_fwddiff(double (double, double)* @tester, double %x, double %dx, double %y, double %dy)
  ret double %d
}

define i32 @main() {
entry:
  ; The primal quotient overflows, but dy is zero.
  %a = call double @tangent(double 1.0e308, double 1.0, double 1.0e-10, double 0.0)
  %a_ok = fcmp oeq double %a, 1.0e10
  ; The primal quotient rounds to zero, but the tangent is normal.
  %b = call double @tangent(double 1.0e-300, double 0.0, double 1.0e100, double 1.0e300)
  %b_scaled = fmul double %b, 1.0e200
  %b_lo = fcmp ogt double %b_scaled, -1.000000000000001
  %b_hi = fcmp olt double %b_scaled, -0.999999999999999
  %b_ok = and i1 %b_lo, %b_hi
  %ok = and i1 %a_ok, %b_ok
  %ret = select i1 %ok, i32 0, i32 1
  ret i32 %ret
}

; CHECK: define internal {{(dso_local )?}}double @fwddiffetester(double %x, double %"x'", double %y)
; CHECK-NEXT: entry:
; CHECK-NEXT:   %0 = fdiv nsz contract double %"x'", %y
; CHECK-NEXT:   ret double %0
; CHECK-NEXT: }

; CHECK: define internal {{(dso_local )?}}double @fwddiffetester.1(double %x, double %y, double %"y'")
; CHECK-NEXT: entry:
; CHECK-NEXT:   %0 = fdiv nsz contract double %"y'", %y
; CHECK-NEXT:   %1 = fmul nsz contract double %0, %x
; CHECK-NEXT:   %2 = fsub nsz contract double 0.000000e+00, %1
; CHECK-NEXT:   %3 = fdiv nsz contract double %2, %y
; CHECK-NEXT:   ret double %3
; CHECK-NEXT: }
