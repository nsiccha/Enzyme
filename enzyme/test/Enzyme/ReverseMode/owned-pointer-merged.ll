; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; Writes through a header merged from fresh allocations cannot invalidate the callee reads.

; Each branch after the call allocates the output, as Julia allocates a
; broadcast's output on each of its branches, and a phi merges the headers.
declare void @__enzyme_autodiff(...)
declare noalias ptr @enzyme_allocator(i64) #0
declare void @consume(ptr) readonly nofree "enzyme_inactive"
declare void @free(ptr)


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
  %r = call double @sqdist(ptr %arr, double %m)
  br i1 %c, label %one, label %two
one:
  %obj.one = call noalias ptr @enzyme_allocator(i64 8), !enzyme_deallocator_fn !0
  br label %merge
two:
  %obj.two = call noalias ptr @enzyme_allocator(i64 16), !enzyme_deallocator_fn !0
  br label %merge
merge:
  %obj = phi ptr [ %obj.one, %one ], [ %obj.two, %two ]
  %buffer = load ptr, ptr %obj
  store double 0.0, ptr %buffer
  call void @consume(ptr %buffer)
  ret double %r
}

define void @test(ptr %arr, double %m, i1 %c) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %arr, double %m, i1 %c)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_deallocator"="-1" "enzyme_fresh_pointer"="0" "enzyme_inactive" }

!0 = !{ptr @free}

; CHECK: define internal void @augmented_sqdist(
; CHECK-NOT: malloc
; CHECK: }
; CHECK: define internal { double } @diffesqdist(
; CHECK: %y_unwrap = load double
