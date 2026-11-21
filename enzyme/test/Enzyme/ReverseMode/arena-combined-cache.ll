; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-caller-owned-tapes=true -enzyme-arena-combined-caches=true -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg),verify" -S | FileCheck %s
; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-caller-owned-tapes=true -enzyme-arena-combined-caches=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg),verify" -S | FileCheck %s --check-prefix=OWN

; A combined derivative caches the values a loop reads before overwriting
; them. With the arena the cache is reserved from the derivative's tape arena,
; which it releases on return, and the cache's own free goes away.
; CHECK-LABEL: define internal {{.*}}@diffesumsq_clear(
; CHECK-NOT: call {{.*}}@malloc(
; CHECK: call {{.*}}@__enzyme_caller_tape_reserve(
; CHECK-NOT: call void @free(
; CHECK: call void @__enzyme_caller_tape_release(
; CHECK-NEXT: ret
; OWN-LABEL: define internal {{.*}}@diffesumsq_clear(
; OWN-NOT: @__enzyme_caller_tape_reserve(
; OWN: call {{.*}}@malloc(
; OWN: call void @free(

target triple = "x86_64-unknown-linux-gnu"

define double @sumsq_clear(ptr %x, i64 %n) {
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

declare void @__enzyme_autodiff(...)
define void @gradient(ptr %x, ptr %dx, i64 %n) {
  call void (...) @__enzyme_autodiff(ptr @sumsq_clear, metadata !"enzyme_dup", ptr %x, ptr %dx, i64 %n)
  ret void
}
