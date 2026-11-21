; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-caller-owned-tapes=true -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg),verify" -S | FileCheck %s
; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-caller-owned-tapes=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg),verify" -S | FileCheck %s --check-prefix=OWN

; The callee squares each value it reads and then overwrites it, so its
; adjoint needs the values it read: a cache of doubles, one per iteration,
; whose length differs between calls and can be zero.
; CHECK-LABEL: define internal {{.*}}@diffecaller(
; CHECK: call {{.*}}@augmented_sumsq_clear(
; CHECK: call void @__enzyme_caller_tape_release(
; CHECK-LABEL: define internal {{.*}}@augmented_sumsq_clear(
; CHECK-NOT: call {{.*}}@malloc(
; CHECK: call {{.*}}@__enzyme_caller_tape_reserve(
; CHECK-NOT: call {{.*}}@malloc(
; CHECK: }
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
  %which = and i64 %i, 3
  %short = icmp ult i64 %which, %n
  %short.len = select i1 %short, i64 %which, i64 %n
  %whole = icmp eq i64 %which, 3
  %len = select i1 %whole, i64 %n, i64 %short.len
  %v = call double @sumsq_clear(ptr %slice, i64 %len)
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
