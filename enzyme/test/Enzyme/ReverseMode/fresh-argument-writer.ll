; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; A later call that writes only the array a function returned after the call
; cannot overwrite what the call read.

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

; Writes the array its first argument names from the second's first element.
define internal void @fill(ptr %out, ptr %arr) #1 {
entry:
  %src = load ptr, ptr %arr
  %x = load double, ptr %src
  %dst = load ptr, ptr %out
  store double %x, ptr %dst
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
  call void @fill(ptr %new, ptr %arr)
  call void @consume(ptr %new)
  ret double %r
}

define void @test(ptr %arr, double %m) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %arr, double %m)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_fresh_pointer"="0" "enzyme_inactive" }
attributes #1 = { "enzyme_inactive" }

; CHECK: define internal void @augmented_sqdist(
; CHECK-NOT: malloc
; CHECK: }
; CHECK: define internal { double } @diffesqdist(
; CHECK: %y_unwrap = load double
