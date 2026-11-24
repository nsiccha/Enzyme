; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-caller-owned-tapes=true -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg),verify" -S | FileCheck %s
; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-caller-owned-tapes=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg),verify" -S | FileCheck %s --check-prefix=OWN

; Only the leaf allocates a bounded cache. The intermediary has no loop or
; cache of its own and must forward the same arena to the leaf. Its reverse
; must use the matching layout even though its own tape has no borrowed slot.
; CHECK-LABEL: define internal {{.*}}@diffecaller(
; CHECK: call {{.*}}@augmented_step({{.*}}, ptr %caller.tape)
; CHECK: call void @__enzyme_caller_tape_release(ptr %caller.tape)
; CHECK-LABEL: define internal {{.*}}@augmented_sumsq_clear(
; CHECK-NOT: call {{.*}}@malloc(
; CHECK: call {{.*}}@__enzyme_caller_tape_reserve(
; CHECK-NOT: call {{.*}}@malloc(
; CHECK: }
; CHECK-LABEL: define internal {{.*}}@augmented_step({{.*}}, ptr %[[ARENA:[^)]+]])
; CHECK: call {{.*}}@augmented_sumsq_clear({{.*}}, ptr %[[ARENA]])
; CHECK-LABEL: define internal {{.*}}@diffesumsq_clear(
; CHECK-NOT: call void @free(
; CHECK: }
; OWN-LABEL: define internal {{.*}}@augmented_sumsq_clear(
; OWN: call {{.*}}@malloc(
; OWN-LABEL: define internal {{.*}}@diffesumsq_clear(
; OWN: call void @free(

target triple = "x86_64-unknown-linux-gnu"

define double @sumsq_clear(ptr %x, i64 %n) noinline nounwind {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %empty.exit, label %loop
empty.exit:
  ret double 0.0
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi double [ 0.0, %entry ], [ %acc, %loop ]
  %xp = getelementptr double, ptr %x, i64 %i
  %v = load double, ptr %xp
  %sq = fmul double %v, %v
  %acc = fadd double %sq, %sum
  store double 0.0, ptr %xp
  %next = add nuw i64 %i, 1
  %more = icmp ult i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  ret double %acc
}


define double @step(ptr %x, i64 %n) noinline nounwind {
  %v = call double @sumsq_clear(ptr %x, i64 %n)
  %vv = fmul double %v, %v
  ret double %vv
}
define double @caller(ptr %x, i64 %n, i64 %calls) {
entry:
  %empty = icmp eq i64 %calls, 0
  br i1 %empty, label %empty.exit, label %loop
empty.exit:
  ret double 0.0
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %sum = phi double [ 0.0, %entry ], [ %acc, %loop ]
  %offset = mul i64 %i, %n
  %slice = getelementptr double, ptr %x, i64 %offset
  %v = call double @step(ptr %slice, i64 %n)
  %acc = fadd double %sum, %v
  %next = add nuw i64 %i, 1
  %more = icmp ult i64 %next, %calls
  br i1 %more, label %loop, label %exit
exit:
  ret double %acc
}

declare void @__enzyme_autodiff(...)
define void @gradient(ptr %x, ptr %dx, i64 %n, i64 %calls) {
  call void (...) @__enzyme_autodiff(ptr @caller, metadata !"enzyme_dup", ptr %x, ptr %dx, i64 %n, i64 %calls)
  ret void
}
