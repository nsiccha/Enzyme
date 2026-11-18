; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; A new header alone does not promise fresh backing storage.

; A split callee reads through an array header. A later write goes through
; a fresh buffer pointer loaded from another allocation's header.
declare void @__enzyme_autodiff(...)
declare noalias ptr @enzyme_allocator(i64) #0
declare void @consume(ptr) readonly nofree "enzyme_inactive"

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

define double @f(ptr %arr, double %m) {
entry:
  %r = call double @sqdist(ptr %arr, double %m)
  %obj = call noalias ptr @enzyme_allocator(i64 8)
  %buffer = load ptr, ptr %obj
  store double 0.0, ptr %buffer
  call void @consume(ptr %buffer)
  ret double %r
}

define void @test(ptr %arr, double %m) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %arr, double %m)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_inactive" }

; CHECK: define internal {{.*}} @augmented_sqdist(
; CHECK: call {{.*}} @malloc(
