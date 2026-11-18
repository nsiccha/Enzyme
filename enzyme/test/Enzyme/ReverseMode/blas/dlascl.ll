; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -S -enzyme-detect-readthrow=0 | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-preopt=false -enzyme-detect-readthrow=0 -S | FileCheck %s

; lascl scales A by cto / cfrom in place. With cfrom and cto inactive, the
; adjoint of the input A is the adjoint of the output scaled the same way.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

declare dso_local void @__enzyme_autodiff(...)

declare void @dlascl_64_(i8* %type, i64* %kl, i64* %ku, double* %cfrom, double* %cto, i64* %m, i64* %n, double* %a, i64* %lda, i64* %info, i64)

define void @f(i8* %type, i64* %kl, i64* %ku, double* %cfrom, double* %cto, i64* %m, i64* %n, double* %a, i64* %lda, i64* %info) {
entry:
  call void @dlascl_64_(i8* %type, i64* %kl, i64* %ku, double* %cfrom, double* %cto, i64* %m, i64* %n, double* %a, i64* %lda, i64* %info, i64 1)
  ret void
}

define void @active(i8* %type, i64* %kl, i64* %ku, double* %cfrom, double* %cto, i64* %m, i64* %n, double* %a, double* %da, i64* %lda, i64* %info) {
entry:
  call void (...) @__enzyme_autodiff(void (i8*, i64*, i64*, double*, double*, i64*, i64*, double*, i64*, i64*)* @f, metadata !"enzyme_const", i8* %type, metadata !"enzyme_const", i64* %kl, metadata !"enzyme_const", i64* %ku, metadata !"enzyme_const", double* %cfrom, metadata !"enzyme_const", double* %cto, metadata !"enzyme_const", i64* %m, metadata !"enzyme_const", i64* %n, metadata !"enzyme_dup", double* %a, double* %da, metadata !"enzyme_const", i64* %lda, metadata !"enzyme_const", i64* %info)
  ret void
}

; CHECK: define internal void @diffef(i8* %type, i64* %kl, i64* %ku, double* %cfrom, double* %cto, i64* %m, i64* %n, double* %a, double* %"a'", i64* %lda, i64* %info)
; CHECK-NEXT: entry:
; CHECK-NEXT:   %ret = alloca double, align 8
; CHECK-NEXT:   %byref.int.one = alloca i64, align 8
; CHECK-NEXT:   %0 = alloca i64, align 8
; CHECK-NEXT:   call void @dlascl_64_(i8* %type, i64* %kl, i64* %ku, double* %cfrom, double* %cto, i64* %m, i64* %n, double* %a, i64* %lda, i64* %info, i64 1)
; CHECK-NEXT:   br label %invertentry

; CHECK: invertentry:
; CHECK-NEXT:   store i64 1, i64* %byref.int.one, align 8
; CHECK-NEXT:   call void @dlascl_64_(i8* %type, i64* %kl, i64* %ku, double* %cfrom, double* %cto, i64* %m, i64* %n, double* %"a'", i64* %lda, i64* %0, i64 1)
; CHECK-NEXT:   ret void
; CHECK-NEXT: }
