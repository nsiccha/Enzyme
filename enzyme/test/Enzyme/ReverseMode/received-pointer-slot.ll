; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; A store into a stack slot cannot overwrite what a call read through a
; pointer the function received.

; The operand is extracted from an aggregate argument, as Julia passes a
; kernel's arrays, so alias analysis cannot separate it from the slot. The
; slot holds a struct a later call takes by reference, as Julia passes one.
declare void @__enzyme_autodiff(...)
declare void @consume(ptr nocapture) readonly nofree "enzyme_inactive"

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

define double @f({ ptr, ptr } %agg, double %m) {
entry:
  %slot = alloca { ptr, i64 }
  %arr = extractvalue { ptr, ptr } %agg, 0
  %other = extractvalue { ptr, ptr } %agg, 1
  %r = call double @sqdist(ptr %arr, double %m)
  store ptr %other, ptr %slot
  %lenp = getelementptr inbounds { ptr, i64 }, ptr %slot, i64 0, i32 1
  store i64 3, ptr %lenp
  call void @consume(ptr %slot)
  ret double %r
}

define void @test({ ptr, ptr } %agg, double %m) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", { ptr, ptr } %agg, double %m)
  ret void
}

; CHECK: define internal void @augmented_sqdist(
; CHECK-NOT: malloc
; CHECK: }
; CHECK: define internal { double } @diffesqdist(
; CHECK: %y_unwrap = load double
