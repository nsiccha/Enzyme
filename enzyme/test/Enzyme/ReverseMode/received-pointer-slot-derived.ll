; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; A store into a stack slot may overwrite what a call read through a pointer
; derived from that slot.

; The operand is extracted from an aggregate loaded from memory, which may hold
; the slot's address, as here: the call read the slot itself.
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

define double @f(ptr %buf, double %m) {
entry:
  %slot = alloca { ptr, i64 }
  store ptr %buf, ptr %slot
  %lenp = getelementptr inbounds { ptr, i64 }, ptr %slot, i64 0, i32 1
  store i64 4, ptr %lenp
  %holder = alloca { ptr, ptr }
  store ptr %slot, ptr %holder
  %agg = load { ptr, ptr }, ptr %holder
  %arr = extractvalue { ptr, ptr } %agg, 0
  %r = call double @sqdist(ptr %arr, double %m)
  store i64 2, ptr %lenp
  call void @consume(ptr %slot)
  ret double %r
}

define void @test(ptr %buf, double %m) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %buf, double %m)
  ret void
}

; CHECK: define internal {{.*}} @augmented_sqdist(
; CHECK: call {{.*}} @malloc(
