; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s

; Under strong zero a zero adjoint gives a zero derivative even where the
; partial derivative is infinite: log at 0 (d / x).

define double @tester(double %x) {
entry:
  %0 = tail call fast double @llvm.log.f64(double %x)
  ret double %0
}

define double @test_derivative(double %x) {
entry:
  %0 = tail call double (double (double)*, ...) @__enzyme_autodiff(double (double)* nonnull @tester, metadata !"enzyme_strong_zero", double %x)
  ret double %0
}

declare double @llvm.log.f64(double)
declare double @__enzyme_autodiff(double (double)*, ...)

; CHECK: define internal { double } @diffetester(double %x, double %differeturn)
; CHECK-NEXT: entry:
; CHECK-NEXT:   %[[d:.+]] = fdiv {{.*}}double %differeturn, %x
; CHECK-NEXT:   %[[z:.+]] = fcmp {{.*}}oeq double %differeturn, 0.000000e+00
; CHECK-NEXT:   %[[r:.+]] = select {{.*}}i1 %[[z]], double 0.000000e+00, double %[[d]]
; CHECK-NEXT:   %[[iv:.+]] = insertvalue { double } {{(undef|poison)}}, double %[[r]], 0
; CHECK-NEXT:   ret { double } %[[iv]]
; CHECK-NEXT: }
