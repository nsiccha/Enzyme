; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; A later call into two functions that call each other may overwrite what the
; call read when one of them writes the storage its argument owns, here the
; operand's.

declare void @__enzyme_autodiff(...)
declare void @consume(ptr) readonly nofree "enzyme_inactive"
declare noalias ptr @malloc(i64)

define internal double @sqdist(ptr %arr, double %m) {
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
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %acc.next
}

define internal void @ping(ptr %a, i64 %n) #1 {
entry:
  %more = icmp sgt i64 %n, 0
  br i1 %more, label %rec, label %exit
rec:
  %n1 = sub i64 %n, 1
  call void @pong(ptr %a, i64 %n1)
  br label %exit
exit:
  ret void
}

define internal void @pong(ptr %a, i64 %n) #1 {
entry:
  %data = load ptr, ptr %a
  store double 0.0, ptr %data
  call void @ping(ptr %a, i64 %n)
  ret void
}

define double @f({ ptr, ptr } %agg, double %m) {
entry:
  %arr = extractvalue { ptr, ptr } %agg, 0
  %r = call double @sqdist(ptr %arr, double %m)
  call void @ping(ptr %arr, i64 3)
  ret double %r
}

define void @test({ ptr, ptr } %agg, double %m) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", { ptr, ptr } %agg, double %m)
  ret void
}

attributes #1 = { nofree "enzyme_inactive" }

; CHECK: define internal {{.*}} @augmented_sqdist(
; CHECK: call {{.*}} @malloc(
