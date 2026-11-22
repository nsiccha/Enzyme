;RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -enzyme-blas-copy=1 -enzyme-lapack-copy=1 -enzyme-detect-readthrow=0 -S | FileCheck %s; fi
;RUN: %opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-blas-copy=1 -enzyme-lapack-copy=1 -enzyme-detect-readthrow=0 -S | FileCheck %s

; A complex routine's scalar is (re, im). The Forward rule of gemv adds each
; tangent term after the first with beta = 1, which must be (1, 0): the splat
; (1, 1) is 1 + im and scaled the earlier terms by it.

;                       trans,                  M,                       N,                     alpha,                  A,    lda,                    x,  , incx,                  beta,                    y,  incy
declare void @zgemv_64_(i8* nocapture readonly, i8* nocapture readonly, i8* nocapture readonly, i8* nocapture readonly, i8* , i8* nocapture readonly, i8*, i8* nocapture readonly, i8* nocapture readonly, i8* , i8* nocapture readonly, i64)

define void @f(i8* noalias %y, i8* noalias %A, i8* noalias %x, i8* noalias %alpha, i8* noalias %beta) {
entry:
  %transa = alloca i8, align 1
  %m = alloca i64, align 16
  %m_p = bitcast i64* %m to i8*
  %n = alloca i64, align 16
  %n_p = bitcast i64* %n to i8*
  %lda = alloca i64, align 16
  %lda_p = bitcast i64* %lda to i8*
  %incx = alloca i64, align 16
  %incx_p = bitcast i64* %incx to i8*
  %incy = alloca i64, align 16
  %incy_p = bitcast i64* %incy to i8*
  store i8 78, i8* %transa, align 1
  store i64 4, i64* %m, align 16
  store i64 4, i64* %n, align 16
  store i64 4, i64* %lda, align 16
  store i64 1, i64* %incx, align 16
  store i64 1, i64* %incy, align 16
  call void @zgemv_64_(i8* %transa, i8* %m_p, i8* %n_p, i8* %alpha, i8* %A, i8* %lda_p, i8* %x, i8* %incx_p, i8* %beta, i8* %y, i8* %incy_p, i64 1)
  ret void
}

declare void @__enzyme_fwddiff(...)

define void @active(i8* %y, i8* %dy, i8* %A, i8* %dA, i8* %x, i8* %dx, i8* %alpha, i8* %beta) {
entry:
  call void (...) @__enzyme_fwddiff(void (i8*,i8*,i8*,i8*,i8*)* @f, metadata !"enzyme_dup", i8* %y, i8* %dy, metadata !"enzyme_dup", i8* %A, i8* %dA, metadata !"enzyme_dup", i8* %x, i8* %dx, metadata !"enzyme_const", i8* %alpha, metadata !"enzyme_const", i8* %beta)
  ret void
}

; CHECK: define internal void @fwddiffef(i8* noalias %y, i8* %"y'", i8* noalias %A, i8* %"A'", i8* noalias %x, i8* %"x'", i8* noalias %alpha, i8* noalias %beta)
; CHECK-NOT: <double 1.000000e+00, double 1.000000e+00>
; CHECK: call void @zgemv_64_(i8* %transa, i8* %m_p, i8* %n_p, i8* %alpha, i8* %A, i8* %lda_p, i8* %"x'", i8* %incx_p, i8* %beta, i8* %"y'", i8* %incy_p, i64 1)
; CHECK-NEXT: store <2 x double> <double 1.000000e+00, double 0.000000e+00>, <2 x double>* %[[one:.+]], align 16
; CHECK-NEXT: %[[onep:.+]] = bitcast <2 x double>* %[[one]] to i8*
; CHECK-NEXT: call void @zgemv_64_(i8* %transa, i8* %m_p, i8* %n_p, i8* %alpha, i8* %"A'", i8* %lda_p, i8* %x, i8* %incx_p, i8* %[[onep]], i8* %"y'", i8* %incy_p, i64 1)
; CHECK-NEXT: call void @zgemv_64_(i8* %transa, i8* %m_p, i8* %n_p, i8* %alpha, i8* %A, i8* %lda_p, i8* %x, i8* %incx_p, i8* %beta, i8* %y, i8* %incy_p, i64 1)
; CHECK-NEXT: ret void
