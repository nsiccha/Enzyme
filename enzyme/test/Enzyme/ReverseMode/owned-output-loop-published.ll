; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; Publishing the raw buffer before the reader makes its later writes visible to the reader.

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
  %obj = call noalias ptr @enzyme_allocator(i64 16)
  %buffer = load ptr, ptr %obj
  %np = getelementptr inbounds i8, ptr %obj, i64 8
  store i64 1, ptr %np
  store double 3.0, ptr %buffer
  store ptr %buffer, ptr %arr
  br label %outer
outer:
  %i = phi i64 [ 0, %entry ], [ %inc, %outer ]
  %total = phi double [ 0.0, %entry ], [ %next, %outer ]
  %r = call double @sqdist(ptr %arr, double %m)
  store double 0.0, ptr %buffer
  %next = fadd double %total, %r
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, 3
  br i1 %done, label %exit, label %outer
exit:
  call void @consume(ptr %obj)
  ret double %next
}

define void @test(ptr %arr, double %m) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %arr, double %m)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_fresh_pointer"="0" "enzyme_inactive" }

; CHECK: define internal {{.*}} @augmented_sqdist(
; CHECK: call {{.*}} @malloc(
