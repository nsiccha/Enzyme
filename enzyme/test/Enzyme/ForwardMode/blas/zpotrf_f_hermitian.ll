;RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -enzyme-lapack-copy=1 -enzyme-detect-readthrow=0 -S | FileCheck %s; fi
;RUN: %opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-lapack-copy=1 -enzyme-detect-readthrow=0 -S | FileCheck %s

; Forward of a complex Cholesky factorization A = L L^H: dL = L Phi(L^{-1} dA L^{-H}).
; The tangent of A is Hermitian, so the copied triangle is conjugated (zlacgv)
; and the imaginary part of its diagonal is dropped; the second solve takes the
; conjugate transpose ('C' = 67); every constant is (v, 0).

declare void @zpotrf_64_(i8* nocapture readonly, i64* nocapture readonly, i8* nocapture, i64* nocapture readonly, i8* nocapture, i64)

define void @f(i8* %A) {
entry:
  %info = alloca i64, align 1
  %info_p = bitcast i64* %info to i8*
  %uplo = alloca i8, align 1
  %n = alloca i64, align 16
  %lda = alloca i64, align 16
  store i8 76, i8* %uplo, align 1
  store i64 4, i64* %n, align 16
  store i64 4, i64* %lda, align 16
  call void @zpotrf_64_(i8* %uplo, i64* %n, i8* %A, i64* %lda, i8* %info_p, i64 1)
  ret void
}

declare void @__enzyme_fwddiff(...)

define void @active(i8* %A, i8* %dA) {
entry:
  call void (...) @__enzyme_fwddiff(void (i8*)* @f, metadata !"enzyme_dup", i8* %A, i8* %dA)
  ret void
}

; CHECK: define internal void @fwddiffef(i8* %A, i8* %"A'")
; CHECK-NOT: <double 1.000000e+00, double 1.000000e+00>
; CHECK-NOT: <double 5.000000e-01, double 5.000000e-01>
; CHECK: call void @zpotrf_64_(i8* %uplo, i64* %n, i8* %A, i64* %lda, i8* %info_p, i64 1)
; CHECK: call void @zcopy_64_(
; CHECK-NEXT: call void @zlacgv_64_(
; CHECK: store double 0.000000e+00, double* %{{.*}}, align 8
; CHECK: %[[nld:.+]] = load i8, i8* %uplo
; CHECK-NEXT: %[[nl:.+]] = icmp eq i8 %[[nld]], 76
; CHECK-NEXT: %[[nlv:.+]] = select i1 %[[nl]], i8 78, i8 110
; CHECK-NEXT: %[[nu:.+]] = icmp eq i8 %[[nld]], 85
; CHECK-NEXT: %[[nuv:.+]] = select i1 %[[nu]], i8 67, i8 %[[nlv]]
; CHECK: store <2 x double> <double 1.000000e+00, double 0.000000e+00>
; CHECK-NEXT: call void @ztrsm_64_(i8* %byref.constant.char.L, i8* %uplo, i8* %byref.uplo_to_normal_conj.uplo,
; CHECK: %[[tld:.+]] = load i8, i8* %uplo
; CHECK-NEXT: %[[tl:.+]] = icmp eq i8 %[[tld]], 76
; CHECK-NEXT: %[[tlv:.+]] = select i1 %[[tl]], i8 67, i8 99
; CHECK: store <2 x double> <double 1.000000e+00, double 0.000000e+00>
; CHECK-NEXT: call void @ztrsm_64_(i8* %byref.constant.char.R, i8* %uplo, i8* %byref.uplo_to_conjtrans.uplo,
; CHECK-NEXT: store <2 x double> <double 5.000000e-01, double 0.000000e+00>
; CHECK: call void @zscal_64_(
; CHECK: call void @ztrmm_64_(

; CHECK: define internal void @__enzyme_copy_lower_to_upperz_64_(i1 %islower, i8* nocapture %A, i64 %lda, i64 %N)
; CHECK: call void @zcopy_64_(i64* %[[cnt:.+]], i8* %{{.*}}, i64* %{{.*}}, i8* %[[dst:.+]], i64* %[[inc:.+]])
; CHECK-NEXT: call void @zlacgv_64_(i64* %[[cnt]], i8* %[[dst]], i64* %[[inc]])
; CHECK: diag:
; CHECK: %[[im:.+]] = getelementptr inbounds double, double* %{{.*}}, i64 1
; CHECK-NEXT: store double 0.000000e+00, double* %[[im]], align 8
