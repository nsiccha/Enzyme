; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; As owned-output-loop-memory-inline.ll, once Julia has moved the Memory to the
; stack: the loop writes the stack slot's inline data directly. Nothing
; exposes the slot to the reader, so those writes cannot overwrite the reader
; inputs, although the slot stores its own address.

declare void @__enzyme_autodiff(...)
declare noalias ptr @object_alloc(i64) #0
declare void @free(ptr)
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

define double @f(ptr %arr, double %m, i1 %c) {
entry:
  %mem = alloca [5 x i64], align 16
  %datap = getelementptr inbounds i8, ptr %mem, i64 8
  %inline = getelementptr inbounds i8, ptr %mem, i64 16
  store ptr %inline, ptr %datap
  store i64 3, ptr %mem
  br label %entry.end
entry.end:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry.end ], [ %inc, %loop ]
  %total = phi double [ 0.0, %entry.end ], [ %next, %loop ]
  %r = call double @sqdist(ptr %arr, double %m)
  %slot = getelementptr inbounds double, ptr %inline, i64 %i
  store double %r, ptr %slot
  %next = fadd double %total, %r
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, 3
  br i1 %done, label %exit, label %loop
exit:
  %first = load double, ptr %inline
  %res = fadd double %next, %first
  ret double %res
}

define void @test(ptr %arr, double %m, i1 %c) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %arr, double %m, i1 %c)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_deallocator"="-1" "enzyme_inactive" }

!0 = !{ptr @free}

; CHECK: define internal double @augmented_sqdist(
; CHECK-NOT: malloc
; CHECK: }
; CHECK: define internal { double } @diffesqdist(
; CHECK: %y_unwrap = load double
