; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; A later call that fills an array it allocates with arrays it computes one by
; one, as Julia's collect does, cannot overwrite what the call read: the calls
; computing the elements write only arrays they allocate themselves, so they
; leave the outer array's storage pointer unchanged.

declare void @__enzyme_autodiff(...)
declare noalias ptr @enzyme_allocator(i64) #0
declare void @consume(ptr) readonly nofree "enzyme_inactive"
declare void @julia.write_barrier(ptr readonly, ...) inaccessiblememonly nofree norecurse nounwind

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

; Returns a new array with its first element zeroed.
define internal noalias ptr @initarray(ptr %arr) #1 {
entry:
  %new = call noalias ptr @enzyme_allocator(i64 8)
  %dst = load ptr, ptr %new
  store double 0.0, ptr %dst
  ret ptr %new
}

define internal noalias ptr @collect(ptr %arr) #1 {
entry:
  %new = call noalias ptr @enzyme_allocator(i64 8)
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %inc, %loop ]
  %elt = call ptr @initarray(ptr %arr)
  %dst = load ptr, ptr %new
  %p = getelementptr inbounds ptr, ptr %dst, i64 %i
  store ptr %elt, ptr %p
  call void (ptr, ...) @julia.write_barrier(ptr %new, ptr %elt)
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, 4
  br i1 %done, label %exit, label %loop
exit:
  ret ptr %new
}

define double @f({ ptr, ptr } %agg, double %m) {
entry:
  %arr = extractvalue { ptr, ptr } %agg, 0
  %r = call double @sqdist(ptr %arr, double %m)
  %new = call ptr @collect(ptr %arr)
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
