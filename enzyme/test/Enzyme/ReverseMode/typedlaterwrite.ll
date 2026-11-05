; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s

; A write after a call may overwrite memory the call read, so the call's
; augmented pass caches what its reverse pass reads from such memory. A store
; of a pointer cannot overwrite memory that holds no pointers: here the doubles
; that @sumsq reads through a pointer it loads. After a store of a pointer
; @sumsq reloads them in its reverse pass; after a store of an integer or a
; double it caches every one of them (Julia may reinterpret doubles as
; integers).

define double @sumsq(double** %pp, i64 %n) {
entry:
  %p = load double*, double** %pp, align 8, !tbaa !2
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %s = phi double [ 0.000000e+00, %entry ], [ %s.next, %loop ]
  %xi.ptr = getelementptr inbounds double, double* %p, i64 %i
  %xi = load double, double* %xi.ptr, align 8, !tbaa !6
  %sq = fmul double %xi, %xi
  %s.next = fadd double %s, %sq
  %i.next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %i.next, %n
  br i1 %done, label %exit, label %loop

exit:
  ret double %s.next
}

; A later store of a pointer, possibly into *%pp itself.
define double @pointerstore(double** %pp, i64 %n, double** %slot, double* %q) {
entry:
  %r = call double @sumsq(double** %pp, i64 %n)
  store double* %q, double** %slot, align 8, !tbaa !2
  ret double %r
}

; A later store of an integer, which may overwrite **%pp.
define double @integerstore(double** %pp, i64 %n, i64* %count) {
entry:
  %r = call double @sumsq(double** %pp, i64 %n)
  %c = load i64, i64* %count, align 8, !tbaa !8
  %c1 = add i64 %c, 1
  store i64 %c1, i64* %count, align 8, !tbaa !8
  ret double %r
}

; A later store of a double, which may overwrite **%pp.
define double @floatstore(double** %pp, i64 %n, double* %out) {
entry:
  %r = call double @sumsq(double** %pp, i64 %n)
  store double 1.000000e+00, double* %out, align 8, !tbaa !6
  ret double %r
}

define void @test(double** %pp, double** %dpp, i64 %n, double** %slot, double* %q, i64* %count, double* %out) {
entry:
  %r0 = call double (...) @__enzyme_autodiff(double (double**, i64, double**, double*)* @pointerstore, metadata !"enzyme_dup", double** %pp, double** %dpp, i64 %n, metadata !"enzyme_const", double** %slot, metadata !"enzyme_const", double* %q)
  %r1 = call double (...) @__enzyme_autodiff(double (double**, i64, i64*)* @integerstore, metadata !"enzyme_dup", double** %pp, double** %dpp, i64 %n, metadata !"enzyme_const", i64* %count)
  %r2 = call double (...) @__enzyme_autodiff(double (double**, i64, double*)* @floatstore, metadata !"enzyme_dup", double** %pp, double** %dpp, i64 %n, metadata !"enzyme_const", double* %out)
  ret void
}

declare double @__enzyme_autodiff(...)

!2 = !{!3, !3, i64 0}
!3 = !{!"any pointer", !4, i64 0}
!4 = !{!"omnipotent char", !5, i64 0}
!5 = !{!"Simple C/C++ TBAA"}
!6 = !{!7, !7, i64 0}
!7 = !{!"double", !4, i64 0}
!8 = !{!9, !9, i64 0}
!9 = !{!"long", !4, i64 0}

; CHECK: define internal void @diffepointerstore(
; CHECK-NEXT: entry:
; CHECK-NEXT:   %r_augmented = call { double*, double* } @augmented_sumsq(double** %pp, double** %"pp'", i64 %n)

; After a store of a pointer, the tape holds the pointer the doubles are read
; through, and no cache of the doubles.
; CHECK: define internal { double*, double* } @augmented_sumsq(double** nocapture readonly %pp, double** nocapture %"pp'", i64 %n)
; CHECK-NOT: @malloc
; CHECK:   %p = load double*, double** %pp
; CHECK-NEXT:   %2 = getelementptr inbounds { double*, double* }, { double*, double* }* %0, i32 0, i32 1
; CHECK-NEXT:   store double* %p, double** %2
; CHECK-NOT: @malloc
; CHECK:   ret { double*, double* }

; The reverse pass reloads the doubles through that pointer.
; CHECK: define internal void @diffesumsq(
; CHECK:   %p = extractvalue { double*, double* } %tapeArg, 1
; CHECK:   %xi.ptr_unwrap = getelementptr inbounds double, double* %p, i64 %"iv'ac.0"
; CHECK-NEXT:   %xi_unwrap = load double, double* %xi.ptr_unwrap

; CHECK: define internal void @diffeintegerstore(
; CHECK-NEXT: entry:
; CHECK-NEXT:   %r_augmented = call { double*, double* } @augmented_sumsq.1(double** %pp, double** %"pp'", i64 %n)

; After a store of an integer or a double, every double is cached.
; CHECK: define internal { double*, double* } @augmented_sumsq.1(double** nocapture readonly %pp, double** nocapture %"pp'", i64 %n)
; CHECK:   %malloccall = tail call noalias nonnull i8* @malloc(i64 %mallocsize)
; CHECK:   %xi = load double, double* %xi.ptr
; CHECK-NEXT:   %3 = getelementptr inbounds double, double* %xi_malloccache, i64 %iv
; CHECK-NEXT:   store double %xi, double* %3

; CHECK: define internal void @diffefloatstore(
; CHECK-NEXT: entry:
; CHECK-NEXT:   %r_augmented = call { double*, double* } @augmented_sumsq.1(double** %pp, double** %"pp'", i64 %n)
