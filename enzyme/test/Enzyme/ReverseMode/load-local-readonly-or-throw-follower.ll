; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; A later call that writes only memory it allocates cannot overwrite what a
; load of this function read, so the reverse pass reloads it.

; The later call returns a new array computed from the operand, as a gather
; Julia does not inline does at the start of the next outer iteration.
declare void @__enzyme_autodiff(...)
declare void @consume(ptr) readonly nofree "enzyme_inactive"
declare ptr @wrap(ptr) nofree "enzyme_LocalReadOnlyOrThrow" "enzyme_inactive"

define double @f(ptr %arr, double %m) {
entry:
  %data = load ptr, ptr %arr
  %np = getelementptr inbounds i8, ptr %arr, i64 8
  %n = load i64, ptr %np
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %inc, %loop ]
  %acc = phi double [ 0.0, %entry ], [ %acc.next, %loop ]
  %p = getelementptr inbounds double, ptr %data, i64 %i
  %y = load double, ptr %p
  %d = fsub double %y, %m
  %sq = fmul double %d, %d
  %acc.next = fadd double %acc, %sq
  %view = call ptr @wrap(ptr %arr)
  call void @consume(ptr %view)
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %acc.next
}

define void @test(ptr %arr, double %m) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %arr, double %m)
  ret void
}

; CHECK: define internal { double } @diffef(
; CHECK-NOT: malloc
; CHECK: %y_unwrap = load double
; CHECK-NOT: malloc
; CHECK: }
