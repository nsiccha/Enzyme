; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; A later call that grows an array it allocates and sets the new element, as
; Julia's push! does on Julia 1.10, cannot overwrite what the call read: the
; resize writes only that array's header and storage made for it.

declare void @__enzyme_autodiff(...)
declare noalias ptr @enzyme_allocator(i64) #0
declare void @consume(ptr) readonly nofree "enzyme_inactive"
declare void @ijl_array_grow_end(ptr, i64) nofree

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

; Returns a new array grown by one element, which it then sets.
define internal noalias ptr @pushed(ptr %arr) #1 {
entry:
  %new = call noalias ptr @enzyme_allocator(i64 8)
  call void @ijl_array_grow_end(ptr %new, i64 1)
  %dst = load ptr, ptr %new
  store double 0.0, ptr %dst
  ret ptr %new
}

define double @f({ ptr, ptr } %agg, double %m) {
entry:
  %arr = extractvalue { ptr, ptr } %agg, 0
  %r = call double @sqdist(ptr %arr, double %m)
  %new = call ptr @pushed(ptr %arr)
  call void @consume(ptr %new)
  ret double %r
}

define void @test({ ptr, ptr } %agg, double %m) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", { ptr, ptr } %agg, double %m)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_fresh_pointer"="0" "enzyme_inactive" }
attributes #1 = { nofree "enzyme_inactive" }

; CHECK: define internal void @augmented_sqdist(
; CHECK-NOT: malloc
; CHECK: }
; CHECK: define internal { double } @diffesqdist(
; CHECK: %y_unwrap = load double
