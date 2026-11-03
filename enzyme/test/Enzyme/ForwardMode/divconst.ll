; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -instsimplify -enzyme-preopt=false -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -passes="enzyme,function(instsimplify)" -enzyme-preopt=false -S | FileCheck %s

; The forward derivative of x / y with only one operand active divides by y and
; never forms y * y, which underflows to zero for |y| < 1.5e-154, and its y term
; goes through y' / y, not through x / y, which may overflow where the tangent
; does not.

define double @tester(double %x, double %y) {
entry:
  %0 = fdiv fast double %x, %y
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

; CHECK: define internal {{(dso_local )?}}double @fwddiffetester(double %x, double %"x'", double %y)
; CHECK-NEXT: entry:
; CHECK-NEXT:   %0 = fdiv fast double %"x'", %y
; CHECK-NEXT:   ret double %0
; CHECK-NEXT: }

; CHECK: define internal {{(dso_local )?}}double @fwddiffetester.1(double %x, double %y, double %"y'")
; CHECK-NEXT: entry:
; CHECK-NEXT:   %0 = fdiv fast double %"y'", %y
; CHECK-NEXT:   %1 = fmul fast double %0, %x
; CHECK-NEXT:   %2 = fsub fast double 0.000000e+00, %1
; CHECK-NEXT:   %3 = fdiv fast double %2, %y
; CHECK-NEXT:   ret double %3
; CHECK-NEXT: }
