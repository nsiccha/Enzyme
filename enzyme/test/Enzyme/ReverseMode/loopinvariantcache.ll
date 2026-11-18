; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -enzyme-loop-invariant-cache=0 -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s --check-prefix=OFF

; A value the reverse pass needs but cannot recompute is cached. One that is
; the same in every iteration of a loop is cached once per entry of that loop.

; @accumulate reads the pointer *%pp in every iteration. Nothing in the loop
; writes *%pp, but its caller overwrites it after the call, so the reverse pass
; of the split call needs the pointer's shadow from the tape: one tape slot,
; not one per iteration.
define void @accumulate(double** %pp, double* noalias %x, i64 %n) {
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = load double*, double** %pp, align 8, !tbaa !2
  %xi.ptr = getelementptr inbounds double, double* %x, i64 %i
  %xi = load double, double* %xi.ptr, align 8, !tbaa !6
  %acc = load double, double* %p, align 8, !tbaa !6
  %sq = fmul double %xi, %xi
  %sum = fadd double %acc, %sq
  store double %sum, double* %p, align 8, !tbaa !6
  %i.next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %i.next, %n
  br i1 %done, label %exit, label %loop

exit:
  ret void
}

define void @split(double** %pp, double* noalias %x, i64 %n) {
entry:
  call void @accumulate(double** %pp, double* %x, i64 %n)
  store double* null, double** %pp, align 8, !tbaa !2
  ret void
}

; *%buf changes in every iteration of the outer loop but in none of the inner
; one: its cache has one entry per outer iteration.
define double @nested(double* noalias %buf, double* noalias %x, double* noalias %w, i64 %n, i64 %m) {
entry:
  br label %outer

outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.latch ]
  %s.outer = phi double [ 0.000000e+00, %entry ], [ %s.inner.lcssa, %outer.latch ]
  %xi.ptr = getelementptr inbounds double, double* %x, i64 %i
  %xi = load double, double* %xi.ptr, align 8, !tbaa !6
  store double %xi, double* %buf, align 8, !tbaa !6
  br label %inner

inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %s = phi double [ %s.outer, %outer ], [ %s.next, %inner ]
  %b = load double, double* %buf, align 8, !tbaa !6
  %wj.ptr = getelementptr inbounds double, double* %w, i64 %j
  %wj = load double, double* %wj.ptr, align 8, !tbaa !6
  %bw = fmul double %b, %wj
  %s.next = fadd double %s, %bw
  %j.next = add nuw nsw i64 %j, 1
  %inner.done = icmp eq i64 %j.next, %m
  br i1 %inner.done, label %outer.latch, label %inner

outer.latch:
  %s.inner.lcssa = phi double [ %s.next, %inner ]
  %i.next = add nuw nsw i64 %i, 1
  %outer.done = icmp eq i64 %i.next, %n
  br i1 %outer.done, label %exit, label %outer

exit:
  store double 0.000000e+00, double* %buf, align 8, !tbaa !6
  ret double %s.inner.lcssa
}

; The loop writes what it reads: one cache entry per iteration.
define double @written(double* noalias %buf, double* noalias %x, i64 %n) {
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %s = phi double [ 0.000000e+00, %entry ], [ %s.next, %loop ]
  %b = load double, double* %buf, align 8, !tbaa !6
  %xi.ptr = getelementptr inbounds double, double* %x, i64 %i
  %xi = load double, double* %xi.ptr, align 8, !tbaa !6
  %bx = fmul double %b, %xi
  %s.next = fadd double %s, %bx
  store double %xi, double* %buf, align 8, !tbaa !6
  %i.next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %i.next, %n
  br i1 %done, label %exit, label %loop

exit:
  store double 0.000000e+00, double* %buf, align 8, !tbaa !6
  ret double %s.next
}

define void @test(double** %pp, double** %dpp, double* %x, double* %dx, double* %buf, double* %dbuf, double* %w, double* %dw, i64 %n, i64 %m) {
entry:
  %r0 = call double (...) @__enzyme_autodiff(void (double**, double*, i64)* @split, metadata !"enzyme_dup", double** %pp, double** %dpp, metadata !"enzyme_dup", double* %x, double* %dx, i64 %n)
  %r1 = call double (...) @__enzyme_autodiff(double (double*, double*, double*, i64, i64)* @nested, metadata !"enzyme_dup", double* %buf, double* %dbuf, metadata !"enzyme_dup", double* %x, double* %dx, metadata !"enzyme_dup", double* %w, double* %dw, i64 %n, i64 %m)
  %r2 = call double (...) @__enzyme_autodiff(double (double*, double*, i64)* @written, metadata !"enzyme_dup", double* %buf, double* %dbuf, metadata !"enzyme_dup", double* %x, double* %dx, i64 %n)
  ret void
}

declare double @__enzyme_autodiff(...)

!2 = !{!3, !3, i64 0}
!3 = !{!"any pointer", !4, i64 0}
!4 = !{!"omnipotent char", !5, i64 0}
!5 = !{!"Simple C/C++ TBAA"}
!6 = !{!7, !7, i64 0}
!7 = !{!"double", !4, i64 0}

; The split call's tape is the shadow pointer itself.
; CHECK: define internal double* @augmented_accumulate(
; CHECK-NOT: @malloc
; CHECK:   %"p'ipl" = load double*, double** %"pp'"
; CHECK:   ret double* %"p'ipl"
; CHECK: define internal void @diffeaccumulate({{.*}}, i64 %n, double* %"p'il_phi")
; CHECK-NOT: @free
; CHECK:   %{{.+}} = load double, double* %"p'il_phi"

; OFF: define internal double** @augmented_accumulate(
; OFF: define internal void @diffeaccumulate({{.*}}, i64 %n, double** %tapeArg)

; CHECK: define internal void @diffenested(
; CHECK: entry:
; CHECK:   %mallocsize = mul nuw nsw i64 %n, 8
; CHECK-NEXT:   %malloccall = tail call noalias nonnull i8* @malloc(i64 %mallocsize)
; CHECK-NEXT:   %b_malloccache = bitcast i8* %malloccall to double*
; CHECK: inner:
; CHECK:   %b = load double, double* %buf
; CHECK-NEXT:   %[[bslot:.+]] = getelementptr inbounds double, double* %b_malloccache, i64 %iv
; CHECK-NEXT:   store double %b, double* %[[bslot]]

; OFF: define internal void @diffenested(
; OFF: entry:
; OFF:   %[[nm:.+]] = mul nuw nsw i64 %m, %n
; OFF-NEXT:   %mallocsize = mul nuw nsw i64 %[[nm]], 8

; CHECK: define internal void @diffewritten(
; CHECK: entry:
; CHECK:   %mallocsize = mul nuw nsw i64 %n, 8
; CHECK: loop:
; CHECK:   %b = load double, double* %buf
; CHECK:   store double %xi, double* %buf
; CHECK-NEXT:   %[[wslot:.+]] = getelementptr inbounds double, double* %b_malloccache, i64 %iv
; CHECK-NEXT:   store double %b, double* %[[wslot]]
