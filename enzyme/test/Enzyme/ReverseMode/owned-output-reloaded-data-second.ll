; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; As owned-output-reloaded-data.ll, with the header on the stack, a second new
; Memory filled in the same loop through its own data pointer, and the header
; passed to a call that throws a bounds error, as a broadcast into two new
; arrays does. The write into the second Memory cannot reach the header: it
; goes through a pointer the header did not derive, and the only call that
; takes the header's address cannot run before it. So the header field keeps
; the first Memory's data pointer and the reader does not cache its inputs.

declare void @__enzyme_autodiff(...)
declare noalias ptr @memory_alloc(i64) #0
declare noalias ptr @object_alloc(i64) #1
declare void @free(ptr)
declare void @consume(ptr) readonly nofree "enzyme_inactive"
declare void @throw_err(ptr) readonly noreturn "enzyme_inactive"

@empty = external global {}, !enzyme_inactive !1, !enzymejl_empty_memory !1
@other = external global {}, !enzyme_inactive !1

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

define double @f(ptr %arr, double %m, i64 %n) {
entry:
  %array = alloca [3 x i64]
  %box = alloca ptr
  %r = call double @sqdist(ptr %arr, double %m)
  %mem = call noalias ptr @memory_alloc(i64 %n), !enzyme_deallocator_fn !0
  store i64 %n, ptr %mem
  %datap = getelementptr inbounds i8, ptr %mem, i64 8
  %data = load ptr, ptr %datap
  store ptr %data, ptr %array
  %lenfield = getelementptr inbounds i8, ptr %array, i64 8
  store i64 %n, ptr %lenfield
  %memfield = getelementptr inbounds i8, ptr %array, i64 16
  store ptr %mem, ptr %memfield
  %mem2 = call noalias ptr @memory_alloc(i64 %n), !enzyme_deallocator_fn !0
  store i64 %n, ptr %mem2
  %datap2 = getelementptr inbounds i8, ptr %mem2, i64 8
  %data2 = load ptr, ptr %datap2
  %isempty = icmp eq i64 %n, 0
  br i1 %isempty, label %exit, label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %inc, %latch ]
  %reload = load ptr, ptr %array
  %slot = getelementptr inbounds double, ptr %reload, i64 %i
  store double %m, ptr %slot
  %slot2 = getelementptr inbounds double, ptr %data2, i64 %i
  store double %m, ptr %slot2
  %bad = icmp ugt i64 %i, %n
  br i1 %bad, label %throw, label %latch
throw:
  call void @throw_err(ptr %array)
  unreachable
latch:
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  call void @consume(ptr %array)
  call void @consume(ptr %data2)
  ret double %r
}

define void @test(ptr %arr, double %m, i64 %n) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %arr, double %m, i64 %n)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_deallocator"="-1" "enzyme_fresh_pointer"="8" "enzyme_inactive" }
attributes #1 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_deallocator"="-1" "enzyme_inactive" }

!0 = !{ptr @free}
!1 = !{}

; CHECK: define internal void @augmented_sqdist(
; CHECK-NOT: malloc
; CHECK: }
; CHECK: define internal { double } @diffesqdist(
; CHECK: %y_unwrap = load double
