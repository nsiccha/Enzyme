; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s

; A loop iteration takes one of three paths into `merge`. `loop` skips
; @checked_sqrt for x <= 0; otherwise `body` calls it and its result decides
; between two more paths. The reverse pass needs the phi %v of the three
; results and recomputes it from %x, which it may reload. It must not call
; @checked_sqrt on the path that skipped it: like Julia's `sqrt`, it throws
; for a negative argument.

declare double @checked_sqrt(double) #0

declare double @__enzyme_autodiff(...)

define double @philoop(double* noalias nocapture readonly %xs, double* noalias nocapture readonly %ys, i64 %n) {
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %inc, %merge ]
  %acc = phi double [ 0.000000e+00, %entry ], [ %acc2, %merge ]
  %xp = getelementptr inbounds double, double* %xs, i64 %i
  %x = load double, double* %xp, align 8
  %early = fcmp ole double %x, 0.000000e+00
  br i1 %early, label %merge, label %body

body:
  %s = call double @checked_sqrt(double %x)
  %big = fcmp oge double %s, 2.000000e+00
  br i1 %big, label %wide, label %narrow

wide:
  %a = fmul double %s, %s
  br label %merge

narrow:
  br label %merge

merge:
  %v = phi double [ 1.000000e+00, %loop ], [ %a, %wide ], [ %s, %narrow ]
  %yp = getelementptr inbounds double, double* %ys, i64 %i
  %y = load double, double* %yp, align 8
  %t = fmul double %v, %y
  %acc2 = fadd double %acc, %t
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop

exit:
  ret double %acc2
}

define double @test(double* %xs, double* %ys, double* %dys, i64 %n) {
entry:
  %r = call double (...) @__enzyme_autodiff(double (double*, double*, i64)* @philoop, metadata !"enzyme_const", double* %xs, double* %ys, double* %dys, i64 %n)
  ret double %r
}

attributes #0 = { nounwind readnone willreturn "enzyme_math"="sqrt" "enzyme_shouldrecompute" }

; CHECK-LABEL: define internal void @diffephiloop(
; CHECK-NOT:    @checked_sqrt
; CHECK:        %early_unwrap = fcmp ole double %x_unwrap, 0.000000e+00
; CHECK-NEXT:   br i1 %early_unwrap, label %{{[^ ]+}}, label %invertmerge_phisplt
; CHECK-NOT:    @checked_sqrt
; CHECK:      invertmerge_phisplt:
; CHECK-NEXT:   %[[s:.+]] = call double @checked_sqrt(double %x_unwrap)
; CHECK-NEXT:   %big_unwrap = fcmp oge double %[[s]], 2.000000e+00
; CHECK-NOT:    @checked_sqrt
; CHECK:      }
