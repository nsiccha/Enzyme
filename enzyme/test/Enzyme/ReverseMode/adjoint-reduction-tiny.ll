; RUN: %opt %defaultLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,simplifycfg)" -S %s -o %t
; RUN: %FileCheck %s < %t
; RUN: %lli %t
; RUN: %opt -passes="default<O2>" -S %t -o %t.opt
; RUN: %lli %t.opt
;
; Unlike an opaque log/exp call, LLVM intrinsics participate in the independence
; proof. The adjoint sum is reassociable, but its tiny per-iteration contribution
; must survive optimization. Globally reassociating its divide and multiply
; would underflow an otherwise representable gradient.

; CHECK-LABEL: define internal {{.*}} @diffetiny(
; CHECK: fdiv nsz contract double
; CHECK: fmul nsz contract double {{.*}}, 1.000000e-190
; CHECK: fadd reassoc nsz contract double

declare double @__enzyme_autodiff(i8*, ...)
declare double @llvm.log.f64(double)
declare double @llvm.exp.f64(double)
declare double @llvm.fabs.f64(double)

define double @tiny(double %x, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi double [ 0.0, %entry ], [ %sum.next, %loop ]
  %y = fmul double %x, 1.0e-190
  %log = call double @llvm.log.f64(double %y)
  %exp = call double @llvm.exp.f64(double %log)
  %negative = fneg double %exp
  %sum.next = fadd reassoc double %sum, %negative
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %sum.next
}

define double @d_tiny(double %x, i64 %n) noinline {
  %g = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i64)* @tiny to i8*), double %x, i64 %n)
  ret double %g
}

define i32 @main() {
  %g = call double @d_tiny(double 1.0, i64 33)
  %ratio = fdiv double %g, -3.3e-189
  %error = fsub double %ratio, 1.0
  %abs = call double @llvm.fabs.f64(double %error)
  %ok = fcmp olt double %abs, 1.0e-12
  %rc = select i1 %ok, i32 0, i32 1
  ret i32 %rc
}
