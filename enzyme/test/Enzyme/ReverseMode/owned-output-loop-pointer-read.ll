; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; An integer read back from the buffer and used as a pointer can name the
; buffer, so the later writes into it may reach the reader in the next iteration.

declare void @__enzyme_autodiff(...)
declare noalias ptr @enzyme_allocator(i64) #0
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

define double @f(ptr %arr, double %m) {
entry:
  br label %outer
outer:
  %i = phi i64 [ 0, %entry ], [ %inc, %outer ]
  %total = phi double [ 0.0, %entry ], [ %next, %outer ]
  %r = call double @sqdist(ptr %arr, double %m)
  %obj = call noalias ptr @enzyme_allocator(i64 16), !enzyme_deallocator_fn !0
  %buffer = load ptr, ptr %obj
  %slot = getelementptr inbounds i8, ptr %buffer, i64 8
  store double %r, ptr %slot
  %bits = load i64, ptr %buffer
  %named = inttoptr i64 %bits to ptr
  call void @consume(ptr %named)
  %next = fadd double %total, %r
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, 3
  br i1 %done, label %exit, label %outer
exit:
  ret double %next
}

define void @test(ptr %arr, double %m) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %arr, double %m)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_deallocator"="-1" "enzyme_fresh_pointer"="0" "enzyme_inactive" }

!0 = !{ptr @free}

; CHECK: define internal {{.*}} @augmented_sqdist(
; CHECK: call {{.*}} @malloc(
