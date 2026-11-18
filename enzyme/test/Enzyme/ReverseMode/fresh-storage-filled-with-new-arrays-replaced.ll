; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; A store that files arrays allocated after the call into another such array
; may overwrite what the call read when a filed array's storage pointer was
; replaced, so that a write through it is no longer a write into storage its
; allocator created: here it points at the outer array's header, and the
; write through it points the outer array at the operand's storage.

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

; Returns a new array.
define internal noalias ptr @newarray() #1 {
entry:
  %new = call noalias ptr @enzyme_allocator(i64 8)
  ret ptr %new
}

define double @f({ ptr, ptr } %agg, double %m) {
entry:
  %arr = extractvalue { ptr, ptr } %agg, 0
  %r = call double @sqdist(ptr %arr, double %m)
  %outer = call ptr @newarray()
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %inc, %latch ]
  %row = call ptr @newarray()
  br label %fill
fill:
  store ptr %outer, ptr %row
  %rdata = load ptr, ptr %row
  %adopted = load ptr, ptr %arr
  store ptr %adopted, ptr %rdata
  %odata = load ptr, ptr %outer
  %slot = getelementptr inbounds ptr, ptr %odata, i64 %i
  store ptr %row, ptr %slot
  br label %latch
latch:
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, 4
  br i1 %done, label %exit, label %loop
exit:
  call void @consume(ptr %outer)
  ret double %r
}

define void @test({ ptr, ptr } %agg, double %m) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", { ptr, ptr } %agg, double %m)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_fresh_pointer"="0" "enzyme_inactive" }
attributes #1 = { nofree "enzyme_inactive" }

; CHECK: define internal {{.*}} @augmented_sqdist(
; CHECK: call {{.*}} @malloc(
