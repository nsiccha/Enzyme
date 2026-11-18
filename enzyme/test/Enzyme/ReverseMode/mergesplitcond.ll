; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s

; Three forward paths join in one block. `entry` returns early for x <= 0
; without calling @checked_sqrt; otherwise `body` calls it and its result
; decides between two more paths. The reverse pass must not call
; @checked_sqrt on the early path: like Julia's `sqrt`, it throws for a
; negative argument.

declare double @checked_sqrt(double) #0

declare void @__enzyme_autodiff(...)

; The merge has no phi: each path stores its result.
define void @stores(double %x, double* %out) {
entry:
  %early = fcmp ole double %x, 0.000000e+00
  br i1 %early, label %neg, label %body

neg:
  %xx = fmul double %x, %x
  store double %xx, double* %out, align 8
  br label %exit

body:
  %s = call double @checked_sqrt(double %x)
  %big = fcmp oge double %s, 2.000000e+00
  br i1 %big, label %wide, label %narrow

wide:
  %a = fmul double %s, %x
  store double %a, double* %out, align 8
  br label %exit

narrow:
  %b = fmul double %s, %s
  store double %b, double* %out, align 8
  br label %exit

exit:
  ret void
}

; The merge has a phi of the three results.
define double @phi(double %x, double %y) {
entry:
  %early = fcmp ole double %x, 0.000000e+00
  br i1 %early, label %exit, label %body

body:
  %s = call double @checked_sqrt(double %x)
  %big = fcmp oge double %s, 2.000000e+00
  br i1 %big, label %wide, label %narrow

wide:
  %a = fmul double %s, %y
  br label %exit

narrow:
  %b = fmul double %s, %s
  br label %exit

exit:
  %r = phi double [ %y, %entry ], [ %a, %wide ], [ %b, %narrow ]
  ret double %r
}

define void @test_stores(double %x, double* %out, double* %dout) {
entry:
  call void (...) @__enzyme_autodiff(void (double, double*)* @stores, double %x, double* %out, double* %dout)
  ret void
}

define void @test_phi(double %x, double %y) {
entry:
  call void (...) @__enzyme_autodiff(double (double, double)* @phi, double %x, double %y)
  ret void
}

attributes #0 = { nounwind readnone willreturn "enzyme_math"="sqrt" "enzyme_shouldrecompute" }

; CHECK-LABEL: define internal { double } @diffestores(
; CHECK: invertexit:
; CHECK-NEXT:   br i1 %early, label %invertneg, label %staging
; CHECK: staging:
; CHECK-NEXT:   %[[s1:.+]] = call double @checked_sqrt(double %x)
; CHECK-NEXT:   %big_unwrap = fcmp oge double %[[s1]], 2.000000e+00
; CHECK-NEXT:   br i1 %big_unwrap, label %invertwide, label %invertnarrow

; CHECK-LABEL: define internal { double, double } @diffephi(
; CHECK-NEXT: entry:
; CHECK-NEXT:   %early = fcmp ole double %x, 0.000000e+00
; CHECK-NEXT:   br i1 %early, label %invertexit, label %body
; CHECK: body:
; CHECK-NEXT:   %s = call double @checked_sqrt(double %x)
; CHECK-NEXT:   %big = fcmp oge double %s, 2.000000e+00
; CHECK-NEXT:   %[[idx:.+]] = select i1 %big, i8 {{[0-9]+}}, i8 {{[0-9]+}}
; CHECK-NEXT:   br label %invertexit
; CHECK: invertexit:
; CHECK-NEXT:   %_cache.0 = phi i8 [ {{[0-9]+}}, %entry ], [ %[[idx]], %body ]
; CHECK-NOT:    @checked_sqrt
; CHECK:        br i1 %early, label %invertentry, label %staging
; CHECK: staging:
; CHECK-NEXT:   %[[s2:.+]] = call double @checked_sqrt(double %x)
; CHECK-NEXT:   %big_unwrap = fcmp oge double %[[s2]], 2.000000e+00
; CHECK-NEXT:   br i1 %big_unwrap, label %invertwide, label %invertnarrow
