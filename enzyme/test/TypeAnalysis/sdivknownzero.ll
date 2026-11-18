; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -print-type-analysis -type-analysis-func=viewindex -o /dev/null | FileCheck %s --check-prefix=VIEW; fi
; RUN: %opt < %s %newLoadEnzyme -passes="print-type-analysis" -type-analysis-func=viewindex -S | FileCheck %s --check-prefix=VIEW
; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -print-type-analysis -type-analysis-func=counted -o /dev/null | FileCheck %s --check-prefix=COUNTED; fi
; RUN: %opt < %s %newLoadEnzyme -passes="print-type-analysis" -type-analysis-func=counted -S | FileCheck %s --check-prefix=COUNTED
; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -print-type-analysis -type-analysis-func=overflow -o /dev/null | FileCheck %s --check-prefix=OVERFLOW; fi
; RUN: %opt < %s %newLoadEnzyme -passes="print-type-analysis" -type-analysis-func=overflow -S | FileCheck %s --check-prefix=OVERFLOW

; Type analysis lists values an integer may take, to find the offsets of a GEP.
; Those lists can hold a divisor the program never divides by, and folding the
; sdiv must not evaluate it: a host division by zero, or INT64_MIN / -1, traps.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; What Julia emits for a linear index into a view with a Vector{Int} index. %n
; is an array length that LLVM replaced by 0 on the edge where it proved the
; array empty, so the list of %n is {0} (%len adds nothing), while the guard
; keeps the loop from running with 0. The list of %i is {0}: this is 0 / 0.
define void @viewindex(i64* %r, i64 %len) {
entry:
  %isempty = icmp eq i64 %len, 0
  br i1 %isempty, label %merge, label %nonempty

nonempty:                                         ; preds = %entry
  br label %merge

merge:                                            ; preds = %nonempty, %entry
  %n = phi i64 [ %len, %nonempty ], [ 0, %entry ]
  %guard = icmp eq i64 %n, 0
  br i1 %guard, label %exit, label %loop

loop:                                             ; preds = %loop, %merge
  %i = phi i64 [ %inext, %loop ], [ 0, %merge ]
  %q = sdiv i64 %i, %n
  %t = mul i64 %q, %n
  %rem = sub i64 %i, %t
  %gep = getelementptr inbounds i64, i64* %r, i64 %rem
  %inext = add i64 %i, 1
  %done = icmp eq i64 %inext, %n
  br i1 %done, label %exit, label %loop

exit:                                             ; preds = %loop, %merge
  ret void
}

; VIEW: viewindex
; VIEW: %q = sdiv i64 %i, %n: {[-1]:Integer}
; VIEW: %rem = sub i64 %i, %t: {[-1]:Integer}

; A counted loop's variable lists every value from 0, here 0 and 3. The value
; that remains still reaches the GEP: 6 / 3 places the double at offset 2 of %p,
; which an i8 GEP with an unknown index could not tell.
define void @counted(i8* %p) {
entry:
  br label %loop

loop:                                             ; preds = %latch, %entry
  %j = phi i64 [ 0, %entry ], [ %jnext, %latch ]
  %jzero = icmp eq i64 %j, 0
  br i1 %jzero, label %latch, label %body

body:                                             ; preds = %loop
  %d = sdiv i64 6, %j
  %gep = getelementptr inbounds i8, i8* %p, i64 %d
  %cast = bitcast i8* %gep to double*
  %v = load double, double* %cast, align 8, !tbaa !0
  br label %latch

latch:                                            ; preds = %body, %loop
  %jnext = add nuw nsw i64 %j, 3
  %exit = icmp eq i64 %jnext, 6
  br i1 %exit, label %done, label %loop

done:                                             ; preds = %latch
  ret void
}

; COUNTED: counted
; COUNTED-NEXT: {{.*}} %p: {[-1]:Pointer, [-1,2]:Float@double}
; COUNTED: %d = sdiv i64 6, %j: {[-1]:Integer}

; INT64_MIN / -1 has no value either, and traps like a division by zero.
define void @overflow(double* %p, i1 %c) {
entry:
  br i1 %c, label %left, label %right

left:                                             ; preds = %entry
  br label %merge

right:                                            ; preds = %entry
  br label %merge

merge:                                            ; preds = %right, %left
  %neg = phi i64 [ -1, %left ], [ 2, %right ]
  %m = sdiv i64 -9223372036854775808, %neg
  %gep = getelementptr inbounds double, double* %p, i64 %m
  ret void
}

; OVERFLOW: overflow
; OVERFLOW: %m = sdiv i64 -9223372036854775808, %neg: {[-1]:Integer}

!0 = !{!1, !1, i64 0}
!1 = !{!"double", !2, i64 0}
!2 = !{!"omnipotent char", !3, i64 0}
!3 = !{!"Simple C++ TBAA"}
