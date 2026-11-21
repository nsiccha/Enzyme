; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes=enzyme -S | FileCheck %s

; A four-way merge in a loop. One arm checks a bound and cannot return
; on failure. The split reverse has no use for that check's condition.
define double @guarded_merge(double* %x, i64 %n, i64 %bound) {
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %next, %merge ]
  %sum = phi double [ 0.0, %entry ], [ %total, %merge ]
  %p = getelementptr inbounds double, double* %x, i64 %i
  %v = load double, double* %p
  %inbounds = icmp ult i64 %i, %bound
  %a = fcmp olt double %v, -1.0
  br i1 %a, label %check, label %b1

check:
  br i1 %inbounds, label %armA, label %fail

fail:
  call void @abort()
  unreachable

armA:
  %va = fmul double %v, 2.0
  br label %merge

b1:
  %b = fcmp olt double %v, 0.0
  br i1 %b, label %armB, label %b2

armB:
  %vb = fmul double %v, 3.0
  br label %merge

b2:
  %c = fcmp olt double %v, 1.0
  br i1 %c, label %armC, label %armD

armC:
  %vc = fmul double %v, 4.0
  br label %merge

armD:
  br label %merge

merge:
  %term = phi double [ %va, %armA ], [ %vb, %armB ], [ %vc, %armC ], [ %v, %armD ]
  %total = fadd double %sum, %term
  %next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop

exit:
  ret double %total
}

define void @reverse(double* %x, double* %dx, i64 %n, i64 %bound, i8* %tape) {
  call void (...) @__enzyme_reverse(double (double*, i64, i64)* @guarded_merge, metadata !"enzyme_not_overwritten", double* %x, double* %dx, i64 %n, i64 %bound, double 1.0, i8* %tape)
  ret void
}

declare void @abort() noreturn
declare void @__enzyme_reverse(...)

; CHECK-LABEL: define internal void @diffeguarded_merge(
; CHECK: invertmerge:
; CHECK-NOT: icmp ult i64 {{.*}}%bound
; CHECK: switch i8
