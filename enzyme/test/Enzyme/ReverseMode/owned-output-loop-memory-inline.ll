; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; A Julia 1.11+ array of short constant length allocated before the loop: its
; Memory is allocated inline, and the function stores the address of the
; Memory's inline data into the Memory's data field before loading it back.
; The array header holds the Memory, and nothing exposes either to the reader,
; so the loop's writes through that data pointer cannot overwrite the reader
; inputs. As Julia does, the function writes the inline data through
; julia.pointer_from_objref, which alias analysis cannot relate to the field.

declare void @__enzyme_autodiff(...)
declare noalias ptr @object_alloc(i64) #0
declare void @free(ptr)
declare void @consume(ptr) readonly nofree "enzyme_inactive"
declare ptr @julia.pointer_from_objref(ptr) #1
declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)

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
  %mem = call noalias ptr @object_alloc(i64 40), !enzyme_deallocator_fn !0
  %datap = getelementptr inbounds i8, ptr %mem, i64 8
  %raw = call ptr @julia.pointer_from_objref(ptr %mem)
  %inline = getelementptr inbounds i8, ptr %raw, i64 16
  store ptr %inline, ptr %datap
  store i64 3, ptr %mem
  call void @llvm.memset.p0.i64(ptr %inline, i8 0, i64 24, i1 false)
  br label %entry.end
entry.end:
  %data = load ptr, ptr %datap
  %array = call noalias ptr @object_alloc(i64 24), !enzyme_deallocator_fn !0
  store ptr %data, ptr %array
  %lenfield = getelementptr inbounds i8, ptr %array, i64 8
  store i64 3, ptr %lenfield
  %memfield = getelementptr inbounds i8, ptr %array, i64 16
  store ptr %mem, ptr %memfield
  br label %loop
loop:
  %i = phi i64 [ 0, %entry.end ], [ %inc, %loop ]
  %total = phi double [ 0.0, %entry.end ], [ %next, %loop ]
  %r = call double @sqdist(ptr %arr, double %m)
  %slot = getelementptr inbounds double, ptr %data, i64 %i
  store double %r, ptr %slot
  %next = fadd double %total, %r
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, 3
  br i1 %done, label %exit, label %loop
exit:
  call void @consume(ptr %array)
  ret double %next
}

define void @test(ptr %arr, double %m, i1 %c) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %arr, double %m, i1 %c)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_deallocator"="-1" "enzyme_inactive" }
attributes #1 = { nounwind readnone "enzyme_inactive" }

!0 = !{ptr @free}

; CHECK: define internal double @augmented_sqdist(
; CHECK-NOT: malloc
; CHECK: }
; CHECK: define internal { double } @diffesqdist(
; CHECK: %y_unwrap = load double
