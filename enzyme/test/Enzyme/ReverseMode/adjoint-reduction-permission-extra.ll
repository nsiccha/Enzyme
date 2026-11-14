; RUN: %opt %defaultLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,simplifycfg)" -S %s -o %t
; RUN: %FileCheck %s < %t
; RUN: %lli %t
; RUN: %opt -passes=instcombine -S %t | %FileCheck %s --check-prefix=OPT
;
; Exercise subtraction both in the primal reduction and the adjoint update,
; division without reassociation, a shared non-reduction use, and aliased state.
; LLVM's reduction-chain analysis currently excludes a primal fsub chain;
; that case stays conservative even though isReductionPHI recognizes it.

; OPT-LABEL: define internal {{.*}} @diffesubtract(
; OPT: fsub reassoc nsz contract double

declare double @__enzyme_autodiff(i8*, ...)
declare double @llvm.fabs.f64(double)

define double @subtract(double %x, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi double [ 0.0, %entry ], [ %sum.next, %loop ]
  %next = add nuw i64 %i, 1
  %d = uitofp i64 %next to double
  %r = fsub double %d, %x
  %square = fmul double %r, %r
  %sum.next = fadd reassoc double %sum, %square
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %sum.next
}

define double @d_subtract(double %x, i64 %n) noinline {
  %g = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i64)* @subtract to i8*), double %x, i64 %n)
  ret double %g
}

define double @negative_sum(double %x, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi double [ 0.0, %entry ], [ %sum.next, %loop ]
  %next = add nuw i64 %i, 1
  %d = uitofp i64 %next to double
  %r = fmul double %d, %x
  %square = fmul double %r, %r
  %sum.next = fsub reassoc double %sum, %square
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %sum.next
}

define double @d_negative_sum(double %x, i64 %n) noinline {
  %g = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i64)* @negative_sum to i8*), double %x, i64 %n)
  ret double %g
}

define double @divide(double %x, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi double [ 0.0, %entry ], [ %sum.next, %loop ]
  %next = add nuw i64 %i, 1
  %d = uitofp i64 %next to double
  %r = fdiv double %d, %x
  %square = fmul double %r, %r
  %sum.next = fadd reassoc double %sum, %square
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %sum.next
}

define double @d_divide(double %x, i64 %n) noinline {
  %g = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i64)* @divide to i8*), double %x, i64 %n)
  ret double %g
}

define double @shared(double %x, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi double [ 0.0, %entry ], [ %sum.next, %loop ]
  %next = add nuw i64 %i, 1
  %d = uitofp i64 %next to double
  %r = fmul double %d, %x
  %square = fmul double %r, %r
  %sum.next = fadd reassoc double %sum, %square
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %ret = fadd double %sum.next, %r
  ret double %ret
}

define double @d_shared(double %x, i64 %n) noinline {
  %g = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i64)* @shared to i8*), double %x, i64 %n)
  ret double %g
}

define double @alias(double %x, i64 %n, double* %state) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi double [ 0.0, %entry ], [ %sum.next, %loop ]
  %old = load double, double* %state
  %new = fmul double %old, %x
  store double %new, double* %state
  %square = fmul double %new, %new
  %sum.next = fadd reassoc double %sum, %square
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %sum.next
}

define double @d_alias(double %x, i64 %n, double* %state, double* %dstate) noinline {
  %g = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i64, double*)* @alias to i8*), double %x, i64 %n, double* %state, double* %dstate)
  ret double %g
}

; CHECK-LABEL: define internal {{.*}} @diffesubtract(
; CHECK: invertloop:
; CHECK-NOT: f{{mul|div}} reassoc
; CHECK: f{{add|sub}} reassoc nsz contract double
; CHECK-NOT: f{{mul|div}} reassoc
; CHECK: }

; CHECK-LABEL: define internal {{.*}} @diffenegative_sum(
; CHECK: invertloop:
; CHECK-NOT: f{{mul|div}} reassoc
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK: fmul nsz contract double
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK-NOT: f{{mul|div}} reassoc
; CHECK: }

; CHECK-LABEL: define internal {{.*}} @diffedivide(
; CHECK: invertloop:
; CHECK-NOT: f{{mul|div}} reassoc
; CHECK: fadd reassoc nsz contract double
; CHECK-NOT: f{{mul|div}} reassoc
; CHECK: }

; CHECK-LABEL: define internal {{.*}} @diffeshared(
; CHECK: invertloop:
; CHECK-NOT: f{{mul|div}} reassoc
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK: fmul nsz contract double
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK-NOT: f{{mul|div}} reassoc
; CHECK: }

; CHECK-LABEL: define internal {{.*}} @diffealias(
; CHECK: invertloop:
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK: fmul nsz contract double
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK: }

define i32 @main() {
  %subtract = call double @d_subtract(double 3.0, i64 5)
  %subtract.err = fsub double %subtract, 0.00000000000000000e+00
  %subtract.abs = call double @llvm.fabs.f64(double %subtract.err)
  %subtract.ok = fcmp olt double %subtract.abs, 1.0e-12
  %negative_sum = call double @d_negative_sum(double 3.0, i64 5)
  %negative_sum.err = fsub double %negative_sum, -3.30000000000000000e+02
  %negative_sum.abs = call double @llvm.fabs.f64(double %negative_sum.err)
  %negative_sum.ok = fcmp olt double %negative_sum.abs, 1.0e-12
  %divide = call double @d_divide(double 3.0, i64 5)
  %divide.err = fsub double %divide, -4.07407407407407440e+00
  %divide.abs = call double @llvm.fabs.f64(double %divide.err)
  %divide.ok = fcmp olt double %divide.abs, 1.0e-12
  %shared = call double @d_shared(double 3.0, i64 5)
  %shared.err = fsub double %shared, 3.35000000000000000e+02
  %shared.abs = call double @llvm.fabs.f64(double %shared.err)
  %shared.ok = fcmp olt double %shared.abs, 1.0e-12
  %state = alloca double
  %dstate = alloca double
  store double 1.0, double* %state
  store double 0.0, double* %dstate
  %alias = call double @d_alias(double 2.0, i64 3, double* %state, double* %dstate)
  %alias.ok = fcmp oeq double %alias, 228.0
  %initial = load double, double* %dstate
  %initial.ok = fcmp oeq double %initial, 168.0
  %ok1 = and i1 %subtract.ok, %negative_sum.ok
  %ok2 = and i1 %divide.ok, %shared.ok
  %ok3 = and i1 %alias.ok, %initial.ok
  %ok4 = and i1 %ok1, %ok2
  %ok = and i1 %ok3, %ok4
  %rc = select i1 %ok, i32 0, i32 1
  ret i32 %rc
}
