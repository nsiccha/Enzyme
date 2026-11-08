; RUN: if [ %llvmver -ge 11 ] && [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme -mem2reg -S | FileCheck %s; fi
; RUN: if [ %llvmver -ge 11 ]; then %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg)" -S | FileCheck %s ; fi
; RUN: if [ %llvmver -ge 11 ]; then %opt < %s %newLoadEnzyme -enzyme-preopt=false -enzyme-select-strong-zero=0 -passes="enzyme,function(mem2reg)" -S | FileCheck %s --check-prefix=OFF ; fi

; A guarded reciprocal `x > t ? 1 / x : 0`, as LLVM speculates it: the division
; runs on every path and a select discards it where the guard is false. There
; the reverse pass gives the division a zero adjoint, and its partials, at
; x = 0, are infinite: without a strong zero, 0 / 0 and 0 * inf make the
; derivative NaN.
define double @guarded(double %x) {
entry:
  %c = fcmp ogt double %x, 1.000000e-12
  %inv = fdiv double 1.000000e+00, %x
  %r = select i1 %c, double %inv, double 0.000000e+00
  ret double %r
}

; A division whose result reaches the return directly keeps its plain rule.
define double @unguarded(double %x) {
entry:
  %inv = fdiv double 1.000000e+00, %x
  %r = fmul double %inv, %x
  ret double %r
}

; A select-masked product of finite values (a ReLU) has no pole, so it keeps
; its plain rule too.
define double @relu(double %x, double %w) {
entry:
  %h = fmul double %w, %x
  %c = fcmp ogt double %h, 0.000000e+00
  %r = select i1 %c, double %h, double 0.000000e+00
  ret double %r
}

define void @main() {
entry:
  %a = call double (...) @__enzyme_autodiff(double (double)* @guarded, double 0.000000e+00)
  %b = call double (...) @__enzyme_autodiff(double (double)* @unguarded, double 2.000000e+00)
  %c = call double (...) @__enzyme_autodiff(double (double, double)* @relu, double 1.000000e+00, double 2.000000e+00)
  ret void
}

declare double @__enzyme_autodiff(...)

; CHECK-LABEL: define internal { double } @diffeguarded(double %x, double %differeturn)
; CHECK: %c = fcmp{{( fast)?}} ogt double %x
; CHECK: %[[d:.+]] = select{{( fast)?}} i1 %c, double %{{[0-9]+}}, double 0.000000e+00
; CHECK-NEXT: %[[q:.+]] = fdiv{{( fast)?}} double %[[d]], %x
; CHECK-NEXT: %[[z:.+]] = fcmp{{( fast)?}} oeq double %[[d]], 0.000000e+00
; CHECK-NEXT: %[[dq:.+]] = select{{( fast)?}} i1 %[[z]], double 0.000000e+00, double %[[q]]
; CHECK-NEXT: %[[r:.+]] = fdiv{{( fast)?}} double 1.000000e+00, %x
; CHECK-NEXT: %[[p:.+]] = fmul{{( fast)?}} double %[[dq]], %[[r]]
; CHECK-NEXT: %[[z2:.+]] = fcmp{{( fast)?}} oeq double %[[dq]], 0.000000e+00
; CHECK-NEXT: %{{.+}} = select{{( fast)?}} i1 %[[z2]], double 0.000000e+00, double %[[p]]
; CHECK: ret { double }

; CHECK-LABEL: define internal { double } @diffeunguarded(double %x, double %differeturn)
; CHECK-NOT: oeq
; CHECK: ret { double }

; CHECK-LABEL: define internal { double, double } @differelu(double %x, double %w, double %differeturn)
; CHECK-NOT: oeq
; CHECK: ret { double, double }

; OFF-LABEL: define internal { double } @diffeguarded(double %x, double %differeturn)
; OFF-NOT: oeq
; OFF: ret { double }
