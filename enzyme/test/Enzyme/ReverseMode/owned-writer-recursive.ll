; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; A later call to a recursive function that writes the storage owned by its
; arguments may overwrite what the call read, even though the function itself
; writes only its first argument's storage: its recursive call swaps them.

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

define internal void @swapfill(ptr %a, ptr %b, i64 %n) #1 {
entry:
  %dst = load ptr, ptr %a
  store double 0.0, ptr %dst
  %more = icmp sgt i64 %n, 0
  br i1 %more, label %rec, label %exit
rec:
  %n1 = sub i64 %n, 1
  call void @swapfill(ptr %b, ptr %a, i64 %n1)
  br label %exit
exit:
  ret void
}

; Returns a new array with its first element zeroed.
define internal noalias ptr @initarray(ptr %arr) #1 {
entry:
  %new = call noalias ptr @enzyme_allocator(i64 8)
  %dst = load ptr, ptr %new
  store double 0.0, ptr %dst
  ret ptr %new
}

define double @f(ptr %arr, double %m) {
entry:
  %r = call double @sqdist(ptr %arr, double %m)
  %new = call ptr @initarray(ptr %arr)
  call void @swapfill(ptr %new, ptr %arr, i64 1)
  call void @consume(ptr %new)
  ret double %r
}

define void @test(ptr %arr, double %m) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %arr, double %m)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_fresh_pointer"="0" "enzyme_inactive" }
attributes #1 = { nofree "enzyme_inactive" }

; CHECK: define internal {{.*}} @augmented_sqdist(
; CHECK: call {{.*}} @malloc(
