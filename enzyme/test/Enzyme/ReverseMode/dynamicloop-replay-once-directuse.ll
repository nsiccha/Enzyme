; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s; fi

; The same search, but its result is used after the loop without passing
; through a phi. A single replayed iteration would give that use the wrong
; value, so the reverse still replays the search in full, and the forward pass
; caches what the replay needs at every step.

define void @gather(ptr noalias %x, ptr noalias %keys, i64 %len, ptr noalias %rows, i64 %n, ptr noalias %out) {
entry:
  br label %outer

outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %found ]
  %acc = phi double [ 0.000000e+00, %entry ], [ %acc.next, %found ]
  %rp = getelementptr inbounds i64, ptr %rows, i64 %i
  %r = load i64, ptr %rp, align 8, !tbaa !4
  br label %search

search:
  %lo = phi i64 [ 0, %outer ], [ %lo.next, %search ]
  %cnt = phi i64 [ %len, %outer ], [ %cnt.next, %search ]
  %half = lshr i64 %cnt, 1
  %mid = add i64 %lo, %half
  %kp = getelementptr inbounds i64, ptr %keys, i64 %mid
  %k = load i64, ptr %kp, align 8, !tbaa !4
  %lt = icmp slt i64 %k, %r
  %mid1 = add i64 %mid, 1
  %lo.next = select i1 %lt, i64 %mid1, i64 %lo
  %rest = sub i64 %cnt, %half
  %rest1 = add i64 %rest, -1
  %cnt.next = select i1 %lt, i64 %rest1, i64 %half
  %done = icmp eq i64 %cnt.next, 0
  br i1 %done, label %found, label %search

found:
  %slot = phi i64 [ %lo.next, %search ]
  %xp = getelementptr inbounds double, ptr %x, i64 %slot
  %xv = load double, ptr %xp, align 8, !tbaa !0
  %sq = fmul double %xv, %xv
  %acc.next = fadd double %acc, %sq
  %i.next = add nuw i64 %i, 1
  %odone = icmp eq i64 %i.next, %n
  br i1 %odone, label %exit, label %outer

exit:
  store double %acc.next, ptr %out, align 8, !tbaa !0
  ret void
}

define ptr @aug(ptr %x, ptr %dx, ptr %keys, i64 %len, ptr %rows, i64 %n, ptr %out, ptr %dout) {
  %t = call ptr (...) @__enzyme_augmentfwd(ptr @gather, ptr %x, ptr %dx, metadata !"enzyme_const", ptr %keys, i64 %len, metadata !"enzyme_const", ptr %rows, i64 %n, ptr %out, ptr %dout)
  ret ptr %t
}

define void @rev(ptr %x, ptr %dx, ptr %keys, i64 %len, ptr %rows, i64 %n, ptr %out, ptr %dout, ptr %tape) {
  call void (...) @__enzyme_reverse(ptr @gather, ptr %x, ptr %dx, metadata !"enzyme_const", ptr %keys, i64 %len, metadata !"enzyme_const", ptr %rows, i64 %n, ptr %out, ptr %dout, ptr %tape)
  ret void
}

declare ptr @__enzyme_augmentfwd(...)
declare void @__enzyme_reverse(...)

!0 = !{!1, !1, i64 0}
!1 = !{!"double", !2, i64 0}
!2 = !{!"omnipotent char", !3, i64 0}
!3 = !{!"Simple C++ TBAA"}
!4 = !{!5, !5, i64 0}
!5 = !{!"long", !2, i64 0}

; CHECK: define internal ptr @augmented_gather(
; CHECK:      search:
; CHECK:        @realloc
; CHECK:        store i64 %cnt.next
; CHECK:        br i1 %done, label %found, label %search

; CHECK: define internal void @diffegather(
; CHECK:      search:
; CHECK:        %lo.next = load i64
; CHECK:        %cnt.next = load i64
; CHECK-NEXT:   %done = icmp eq i64 %cnt.next, 0
; CHECK-NEXT:   br i1 %done, label %found, label %search
