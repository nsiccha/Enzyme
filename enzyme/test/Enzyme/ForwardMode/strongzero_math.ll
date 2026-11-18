; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -enzyme-preopt=false -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-preopt=false -S | FileCheck %s

; Under strong zero a zero tangent gives a zero derivative even where the
; partial derivative is infinite: log at 0 (dx / x) and exp at +inf (exp(x) * dx).

define double @tester_log(double %x) {
entry:
  %0 = tail call fast double @llvm.log.f64(double %x)
  ret double %0
}

define double @tester_exp(double %x) {
entry:
  %0 = tail call fast double @llvm.exp.f64(double %x)
  ret double %0
}

define double @test_log(double %x, double %dx) {
entry:
  %0 = tail call double (double (double)*, ...) @__enzyme_fwddiff(double (double)* nonnull @tester_log, metadata !"enzyme_strong_zero", double %x, double %dx)
  ret double %0
}

define double @test_exp(double %x, double %dx) {
entry:
  %0 = tail call double (double (double)*, ...) @__enzyme_fwddiff(double (double)* nonnull @tester_exp, metadata !"enzyme_strong_zero", double %x, double %dx)
  ret double %0
}

declare double @llvm.log.f64(double)
declare double @llvm.exp.f64(double)
declare double @__enzyme_fwddiff(double (double)*, ...)

; CHECK: define internal double @fwddiffetester_log(double %x, double %"x'")
; CHECK-NEXT: entry:
; CHECK-NEXT:   %[[d:.+]] = fdiv {{.*}}double %"x'", %x
; CHECK-NEXT:   %[[z:.+]] = fcmp {{.*}}oeq double %"x'", 0.000000e+00
; CHECK-NEXT:   %[[r:.+]] = select {{.*}}i1 %[[z]], double 0.000000e+00, double %[[d]]
; CHECK-NEXT:   ret double %[[r]]
; CHECK-NEXT: }

; CHECK: define internal double @fwddiffetester_exp(double %x, double %"x'")
; CHECK-NEXT: entry:
; CHECK-NEXT:   %[[e:.+]] = call {{.*}}double @llvm.exp.f64(double %x)
; CHECK-NEXT:   %[[m:.+]] = fmul {{.*}}double %"x'", %[[e]]
; CHECK-NEXT:   %[[z2:.+]] = fcmp {{.*}}oeq double %"x'", 0.000000e+00
; CHECK-NEXT:   %[[r2:.+]] = select {{.*}}i1 %[[z2]], double 0.000000e+00, double %[[m]]
; CHECK-NEXT:   ret double %[[r2]]
; CHECK-NEXT: }
