; RUN: %opt %defaultLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,simplifycfg)" -S %s -o %t
; RUN: %FileCheck %s < %t
; RUN: %lli %t
; RUN: %opt %defaultLoadEnzyme -enzyme-fast-math-flags=0 -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,simplifycfg)" -S %s | %FileCheck %s --check-prefix=GLOBAL-STRICT
;
; An author-permitted additive reduction licenses only its independent
; loop-invariant SSA adjoint sums. Multiplication and division keep the default
; nsz+contract policy. A strict reduction, an observed prefix sum, writes and an
; unrelated reassociable expression do not confer this permission.
; Clearing global fast-math flags does not clear explicit primal permission.

; GLOBAL-STRICT-LABEL: define internal {{.*}} @diffepermitted(
; GLOBAL-STRICT: invertloop:
; GLOBAL-STRICT: fmul double
; GLOBAL-STRICT: fadd reassoc double
; GLOBAL-STRICT-NOT: nsz
; GLOBAL-STRICT: }

declare double @__enzyme_autodiff(i8*, ...)
declare double @llvm.fabs.f64(double)

define double @permitted(double %x, i64 %n, double* %out) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi double [ 0.0, %entry ], [ %sum.next, %loop ]
  %next = add nuw i64 %i, 1
  %d = uitofp i64 %next to double
  %p = fmul double %x, %d
  %r = fsub double %d, %p
  %square = fmul double %r, %r
  %sum.next = fadd reassoc double %sum, %square
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %sum.next
}

define double @d_permitted(double %x, i64 %n, double* %out) noinline {
  %g = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i64, double*)* @permitted to i8*), double %x, i64 %n, metadata !"enzyme_const", double* %out)
  ret double %g
}

define double @strict(double %x, i64 %n, double* %out) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi double [ 0.0, %entry ], [ %sum.next, %loop ]
  %next = add nuw i64 %i, 1
  %d = uitofp i64 %next to double
  %p = fmul double %x, %d
  %r = fsub double %d, %p
  %square = fmul double %r, %r
  %sum.next = fadd double %sum, %square
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %sum.next
}

define double @d_strict(double %x, i64 %n, double* %out) noinline {
  %g = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i64, double*)* @strict to i8*), double %x, i64 %n, metadata !"enzyme_const", double* %out)
  ret double %g
}

define double @prefix(double %x, i64 %n, double* %out) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi double [ 0.0, %entry ], [ %sum.next, %loop ]
  %next = add nuw i64 %i, 1
  %d = uitofp i64 %next to double
  %p = fmul double %x, %d
  %r = fsub double %d, %p
  %prefix.use = fadd double %r, %sum
  %square = fmul double %prefix.use, %prefix.use
  %sum.next = fadd reassoc double %sum, %square
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %sum.next
}

define double @d_prefix(double %x, i64 %n, double* %out) noinline {
  %g = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i64, double*)* @prefix to i8*), double %x, i64 %n, metadata !"enzyme_const", double* %out)
  ret double %g
}

define double @writes(double %x, i64 %n, double* %out) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi double [ 0.0, %entry ], [ %sum.next, %loop ]
  %next = add nuw i64 %i, 1
  %d = uitofp i64 %next to double
  %p = fmul double %x, %d
  %r = fsub double %d, %p
  %square = fmul double %r, %r
  %ptr = getelementptr double, double* %out, i64 %i
  store double %square, double* %ptr
  %sum.next = fadd reassoc double %sum, %square
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %sum.next
}

define double @d_writes(double %x, i64 %n, double* %out) noinline {
  %g = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i64, double*)* @writes to i8*), double %x, i64 %n, metadata !"enzyme_const", double* %out)
  ret double %g
}

define double @unrelated(double %x, i64 %n, double* %out) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi double [ 0.0, %entry ], [ %sum.next, %loop ]
  %next = add nuw i64 %i, 1
  %d = uitofp i64 %next to double
  %p = fmul double %x, %d
  %r = fsub double %d, %p
  %unused.permission = fadd reassoc double %r, 1.0
  %square = fmul double %unused.permission, %unused.permission
  %sum.next = fadd double %sum, %square
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %sum.next
}

define double @d_unrelated(double %x, i64 %n, double* %out) noinline {
  %g = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i64, double*)* @unrelated to i8*), double %x, i64 %n, metadata !"enzyme_const", double* %out)
  ret double %g
}

; CHECK-LABEL: define internal {{.*}} @diffepermitted(
; CHECK: invertloop:
; CHECK: fmul nsz contract double
; CHECK: f{{add|sub}} reassoc nsz contract double
; CHECK: }

; CHECK-LABEL: define internal {{.*}} @diffestrict(
; CHECK: invertloop:
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK: fmul nsz contract double
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK: }

; CHECK-LABEL: define internal {{.*}} @diffeprefix(
; CHECK: invertloop:
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK: fmul nsz contract double
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK: }

; CHECK-LABEL: define internal {{.*}} @diffewrites(
; CHECK: invertloop:
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK: fmul nsz contract double
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK: }

; CHECK-LABEL: define internal {{.*}} @diffeunrelated(
; CHECK: invertloop:
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK: fmul nsz contract double
; CHECK-NOT: f{{add|sub}} reassoc nsz contract
; CHECK: }

define i32 @main() {
  %a = call double @d_permitted(double 3.0, i64 5, double* null)
  %b = call double @d_strict(double 3.0, i64 5, double* null)
  %ae = fsub double %a, 220.0
  %be = fsub double %b, 220.0
  %aa = call double @llvm.fabs.f64(double %ae)
  %ba = call double @llvm.fabs.f64(double %be)
  %ca = fcmp olt double %aa, 1.0e-12
  %cb = fcmp olt double %ba, 1.0e-12
  %ok = and i1 %ca, %cb
  %rc = select i1 %ok, i32 0, i32 1
  ret i32 %rc
}
