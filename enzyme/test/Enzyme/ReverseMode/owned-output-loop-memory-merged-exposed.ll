; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; As owned-output-loop-memory-merged.ll, but the reader reads the array the loop
; writes, so the new Memory is exposed to it through the header that holds it
; and the later writes overwrite what it read: it still caches its inputs.

declare void @__enzyme_autodiff(...)
declare noalias ptr @memory_alloc(i64) #0
declare noalias ptr @object_alloc(i64) #1
declare void @free(ptr)
declare void @consume(ptr) readonly nofree "enzyme_inactive"

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
  %isempty = icmp eq i64 %n, 0
  br i1 %isempty, label %emptymem, label %alloc
emptymem:
  %edata = load ptr, ptr getelementptr inbounds (i8, ptr @empty, i64 8)
  br label %join
alloc:
  %mem = call noalias ptr @memory_alloc(i64 %n), !enzyme_deallocator_fn !0
  store i64 %n, ptr %mem
  %datap = getelementptr inbounds i8, ptr %mem, i64 8
  %fdata = load ptr, ptr %datap
  br label %join
join:
  %data = phi ptr [ %edata, %emptymem ], [ %fdata, %alloc ]
  %memory = phi ptr [ @empty, %emptymem ], [ %mem, %alloc ]
  %array = call noalias ptr @object_alloc(i64 24), !enzyme_deallocator_fn !0
  store ptr %data, ptr %array
  %lenfield = getelementptr inbounds i8, ptr %array, i64 8
  store i64 %n, ptr %lenfield
  %memfield = getelementptr inbounds i8, ptr %array, i64 16
  store ptr %memory, ptr %memfield
  br i1 %isempty, label %exit, label %loop
loop:
  %i = phi i64 [ 0, %join ], [ %inc, %loop ]
  %total = phi double [ 0.0, %join ], [ %next, %loop ]
  %r = call double @sqdist(ptr %array, double %m)
  %slot = getelementptr inbounds double, ptr %data, i64 %i
  store double %r, ptr %slot
  %next = fadd double %total, %r
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %res = phi double [ 0.0, %join ], [ %next, %loop ]
  call void @consume(ptr %array)
  ret double %res
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

; CHECK: define internal {{.*}} @augmented_sqdist(
; CHECK: call {{.*}} @malloc(
