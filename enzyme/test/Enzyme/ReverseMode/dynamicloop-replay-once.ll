; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s; fi

; A binary search over constant keys inside a gather loop: the search loop's
; limit cannot be computed, its body is inactive, and its result leaves it only
; through a phi. The split reverse pass replays that loop once, so the forward
; pass caches only the found slot per gather iteration, not the search's exit
; test at every step (which grew a buffer with realloc per gather iteration).

define void @gather(ptr noalias %x, ptr noalias %keys, i64 %len, ptr noalias %rows, i64 %n, ptr noalias %out) {
entry:
  br label %outer

outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %found ]
  %acc = phi double [ 0.000000e+00, %entry ], [ %acc.next, %found ]
  %rp = getelementptr inbounds i64, ptr %rows, i64 %i
  %r = load i64, ptr %rp, align 8, !tbaa !4
  %empty = icmp eq i64 %len, 0
  br i1 %empty, label %found, label %search

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
  br i1 %done, label %search.exit, label %search

search.exit:
  br label %found

found:
  %slot = phi i64 [ 0, %outer ], [ %lo.next, %search.exit ]
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

; The tape holds the slot and the loaded value, one per gather iteration.

; CHECK: define internal ptr @augmented_gather(
; CHECK-NEXT: entry:
; CHECK-NEXT:   %[[tape:.+]] = {{(tail )?}}call noalias nonnull dereferenceable(16) dereferenceable_or_null(16) ptr @malloc(i64 16)
; CHECK:      search:
; CHECK-NOT:    store
; CHECK-NOT:    @realloc
; CHECK:        br i1 %done, label %found, label %search
; CHECK:      found:
; CHECK-NEXT:   %slot = phi i64 [ 0, %outer ], [ %lo.next, %search ]
; CHECK-NEXT:   %[[sptr:.+]] = getelementptr inbounds {{(nuw )?}}i64, ptr %{{.+}}, i64 %iv
; CHECK-NEXT:   store i64 %slot, ptr %[[sptr]], align 8, !invariant.group
; CHECK:        ret ptr %[[tape]]
; CHECK-NEXT: }

; The reverse replays the search once: it neither loops nor reads the tape there.

; CHECK: define internal void @diffegather(
; CHECK:      search:
; CHECK-NOT:    load
; CHECK:        br label %found
; CHECK:      found:
; CHECK-NOT:  @realloc
