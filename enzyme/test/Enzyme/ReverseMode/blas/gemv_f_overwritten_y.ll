;RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -enzyme-blas-copy=1 -enzyme-lapack-copy=1 -enzyme-detect-readthrow=0 -S | FileCheck %s; fi
;RUN: %opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-blas-copy=1 -enzyme-lapack-copy=1 -enzyme-detect-readthrow=0 -S | FileCheck %s

; y := alpha A x + beta y. The adjoint of what y held before the call is
; beta * dy, with BLAS semantics for beta: beta == 0 overwrites y without
; reading it, so its adjoint must be overwritten with zero as well. scal(beta,
; dy) multiplies, and 0 * NaN is NaN: a shadow that is used again (the same
; output buffer in a second reverse pass) then keeps the NaN.

;                       trans,                  M,                       N,                     alpha,                  A,    lda,                    x,  , incx,                  beta,                    y,  incy
declare void @dgemv_64_(i8* nocapture readonly, i8* nocapture readonly, i8* nocapture readonly, i8* nocapture readonly, i8* , i8* nocapture readonly, i8*, i8* nocapture readonly, i8* nocapture readonly, i8* , i8* nocapture readonly, i64)

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
  store i64 -2, i64* %incy, align 16
  call void @dgemv_64_(i8* %transa, i8* %m_p, i8* %n_p, i8* %alpha, i8* %A, i8* %lda_p, i8* %x, i8* %incx_p, i8* %beta, i8* %y, i8* %incy_p, i64 1)
  ret void
}

declare dso_local void @__enzyme_autodiff(...)

define void @active(i8* %y, i8* %dy, i8* %A, i8* %x, i8* %alpha, i8* %beta) {
entry:
  call void (...) @__enzyme_autodiff(void (i8*,i8*,i8*,i8*,i8*)* @f, metadata !"enzyme_dup", i8* %y, i8* %dy, metadata !"enzyme_const", i8* %A, metadata !"enzyme_const", i8* %x, metadata !"enzyme_const", i8* %alpha, metadata !"enzyme_const", i8* %beta)
  ret void
}

; CHECK: define internal void @diffef(i8* noalias %y, i8* %"y'", i8* noalias %A, i8* noalias %x, i8* noalias %alpha, i8* noalias %beta)
; CHECK-NEXT: entry:
; CHECK-NEXT:   %ret = alloca double, align 8
; CHECK-NEXT:   %byref.int.one = alloca i64, align 8
; CHECK-NEXT:   %transa = alloca i8, align 1
; CHECK-NEXT:   %m = alloca i64, align 16
; CHECK-NEXT:   %m_p = bitcast i64* %m to i8*
; CHECK-NEXT:   %n = alloca i64, align 16
; CHECK-NEXT:   %n_p = bitcast i64* %n to i8*
; CHECK-NEXT:   %lda = alloca i64, align 16
; CHECK-NEXT:   %lda_p = bitcast i64* %lda to i8*
; CHECK-NEXT:   %incx = alloca i64, align 16
; CHECK-NEXT:   %incx_p = bitcast i64* %incx to i8*
; CHECK-NEXT:   %incy = alloca i64, align 16
; CHECK-NEXT:   %incy_p = bitcast i64* %incy to i8*
; CHECK-NEXT:   store i8 78, i8* %transa, align 1
; CHECK-NEXT:   store i64 4, i64* %m, align 16
; CHECK-NEXT:   store i64 4, i64* %n, align 16
; CHECK-NEXT:   store i64 4, i64* %lda, align 16
; CHECK-NEXT:   store i64 1, i64* %incx, align 16
; CHECK-NEXT:   store i64 -2, i64* %incy, align 16
; CHECK-NEXT:   call void @dgemv_64_(i8* %transa, i8* %m_p, i8* %n_p, i8* %alpha, i8* %A, i8* %lda_p, i8* %x, i8* %incx_p, i8* %beta, i8* %y, i8* %incy_p, i64 1)
; CHECK-NEXT:   br label %invertentry
; CHECK: invertentry:                                      ; preds = %entry
; CHECK-NEXT:   store i64 1, i64* %byref.int.one, align 4
; CHECK-NEXT:   %ld.row.trans = load i8, i8* %transa, align 1
; CHECK-NEXT:   %[[soz1:.+]] = icmp eq i8 %ld.row.trans, 110
; CHECK-NEXT:   %[[soz2:.+]] = icmp eq i8 %ld.row.trans, 78
; CHECK-NEXT:   %[[soz3:.+]] = or i1 %[[soz2]], %[[soz1]]
; CHECK-NEXT:   %[[soz4:.+]] = select i1 %[[soz3]], i8* %m_p, i8* %n_p
; CHECK-NEXT:   %[[soz5:.+]] = bitcast i8* %[[soz4]] to i64*
; CHECK-NEXT:   %[[soz6:.+]] = load i64, i64* %[[soz5]], align 4
; CHECK-NEXT:   %[[soz7:.+]] = bitcast i8* %incy_p to i64*
; CHECK-NEXT:   %[[soz8:.+]] = load i64, i64* %[[soz7]], align 4
; CHECK-NEXT:   %[[soz9:.+]] = bitcast i8* %beta to double*
; CHECK-NEXT:   %[[soz10:.+]] = load double, double* %[[soz9]], align 8
; CHECK-NEXT:   %[[soz11:.+]] = sub i64 0, %[[soz8]]
; CHECK-NEXT:   %[[soz12:.+]] = icmp slt i64 %[[soz8]], 0
; CHECK-NEXT:   %[[soz13:.+]] = select i1 %[[soz12]], i64 %[[soz11]], i64 %[[soz8]]
; CHECK-NEXT:   %[[soz14:.+]] = bitcast i8* %"y'" to double*
; CHECK-NEXT:   %identity.i = fcmp oeq double %[[soz10]], 1.000000e+00
; CHECK-NEXT:   %[[soz15:.+]] = icmp sle i64 %[[soz6]], 0
; CHECK-NEXT:   %[[soz16:.+]] = or i1 %[[soz15]], %identity.i
; CHECK-NEXT:   br i1 %[[soz16]], label %__enzyme_scale_or_zero_double_64.exit, label %init.i
; CHECK: init.i:                                           ; preds = %invertentry
; CHECK-NEXT:   %overwrite.i = fcmp oeq double %[[soz10]], 0.000000e+00
; CHECK-NEXT:   %[[soz38:.+]] = icmp eq i64 %[[soz13]], 1
; CHECK-NEXT:   br i1 %[[soz38]], label %flat.i, label %col.i
; CHECK: flat.i:                                           ; preds = %init.i
; CHECK-NEXT:   br i1 %overwrite.i, label %flat.zero.i, label %flat.scale.i
; CHECK: flat.zero.i:                                      ; preds = %flat.i
; CHECK-NEXT:   %[[soz39:.+]] = mul nuw nsw i64 %[[soz6]], 8
; CHECK-NEXT:   call void @llvm.memset.p0i8.i64(i8* %"y'", i8 0, i64 %[[soz39]], i1 false)
; CHECK-NEXT:   br label %__enzyme_scale_or_zero_double_64.exit
; CHECK: flat.scale.i:                                     ; preds = %flat.scale.i, %flat.i
; CHECK-NEXT:   %k.i = phi i64 [ 0, %flat.i ], [ %k.next.i, %flat.scale.i ]
; CHECK-NEXT:   %out.k.i = getelementptr inbounds double, double* %[[soz14]], i64 %k.i
; CHECK-NEXT:   %[[soz40:.+]] = load double, double* %out.k.i, align 8
; CHECK-NEXT:   %scaled.k.i = fmul double %[[soz10]], %[[soz40]]
; CHECK-NEXT:   store double %scaled.k.i, double* %out.k.i, align 8
; CHECK-NEXT:   %k.next.i = add nuw nsw i64 %k.i, 1
; CHECK-NEXT:   %[[soz41:.+]] = icmp eq i64 %k.next.i, %[[soz6]]
; CHECK-NEXT:   br i1 %[[soz41]], label %__enzyme_scale_or_zero_double_64.exit, label %flat.scale.i
; CHECK: col.i:                                            ; preds = %col.end.i, %init.i
; CHECK-NEXT:   %j.i = phi i64 [ 0, %init.i ], [ %j.next.i, %col.end.i ]
; CHECK-NEXT:   %j.next.i = add nuw nsw i64 %j.i, 1
; CHECK-NEXT:   %[[soz17:.+]] = icmp slt i64 %j.i, 1
; CHECK-NEXT:   %[[soz18:.+]] = select i1 %[[soz17]], i64 %j.i, i64 1
; CHECK-NEXT:   %col.offset.i = mul nuw nsw i64 %j.i, %[[soz13]]
; CHECK-NEXT:   br label %row.i
; CHECK: row.i:                                            ; preds = %row.i, %col.i
; CHECK-NEXT:   %i.i = phi i64 [ 0, %col.i ], [ %i.next.i, %row.i ]
; CHECK-NEXT:   %[[soz19:.+]] = add nuw nsw i64 %i.i, %col.offset.i
; CHECK-NEXT:   %out.i.i = getelementptr inbounds double, double* %[[soz14]], i64 %[[soz19]]
; CHECK-NEXT:   %[[soz20:.+]] = load double, double* %out.i.i, align 8
; CHECK-NEXT:   %scaled.i = fmul double %[[soz10]], %[[soz20]]
; CHECK-NEXT:   %[[soz21:.+]] = select i1 %overwrite.i, double 0.000000e+00, double %scaled.i
; CHECK-NEXT:   store double %[[soz21]], double* %out.i.i, align 8
; CHECK-NEXT:   %i.next.i = add nuw nsw i64 %i.i, 1
; CHECK-NEXT:   %[[soz22:.+]] = icmp eq i64 %i.next.i, 1
; CHECK-NEXT:   br i1 %[[soz22]], label %col.end.i, label %row.i
; CHECK: col.end.i:                                        ; preds = %row.i
; CHECK-NEXT:   %[[soz23:.+]] = icmp eq i64 %j.next.i, %[[soz6]]
; CHECK-NEXT:   br i1 %[[soz23]], label %__enzyme_scale_or_zero_double_64.exit, label %col.i
; CHECK: __enzyme_scale_or_zero_double_64.exit:            ; preds = %invertentry, %flat.zero.i, %flat.scale.i, %col.end.i
; CHECK-NEXT:   ret void
; CHECK-NEXT: }

; CHECK: define internal void @__enzyme_scale_or_zero_double_64(i8 %uplo, i64 %m, i64 %n, double %scale, double* nocapture %out, i64 %ld)
; CHECK-NEXT: entry:
; CHECK-NEXT:   %identity = fcmp oeq double %scale, 1.000000e+00
; CHECK-NEXT:   %[[soz24:.+]] = icmp sle i64 %n, 0
; CHECK-NEXT:   %[[soz25:.+]] = icmp sle i64 %m, 0
; CHECK-NEXT:   %[[soz26:.+]] = or i1 %[[soz25]], %[[soz24]]
; CHECK-NEXT:   %[[soz27:.+]] = or i1 %[[soz26]], %identity
; CHECK-NEXT:   br i1 %[[soz27]], label %end, label %init
; CHECK: init:                                             ; preds = %entry
; CHECK-NEXT:   %overwrite = fcmp oeq double %scale, 0.000000e+00
; CHECK-NEXT:   %upper = icmp eq i8 %uplo, 85
; CHECK-NEXT:   %lower = icmp eq i8 %uplo, 76
; CHECK-NEXT:   %[[soz42:.+]] = icmp eq i64 %ld, %m
; CHECK-NEXT:   %[[soz43:.+]] = or i1 %upper, %lower
; CHECK-NEXT:   %[[soz44:.+]] = xor i1 %[[soz43]], true
; CHECK-NEXT:   %contiguous = and i1 %[[soz44]], %[[soz42]]
; CHECK-NEXT:   br i1 %contiguous, label %flat, label %col
; CHECK: flat:                                             ; preds = %init
; CHECK-NEXT:   %total = mul nuw nsw i64 %m, %n
; CHECK-NEXT:   br i1 %overwrite, label %flat.zero, label %flat.scale
; CHECK: flat.zero:                                        ; preds = %flat
; CHECK-NEXT:   %[[soz45:.+]] = mul nuw nsw i64 %total, 8
; CHECK-NEXT:   %[[soz46:.+]] = bitcast double* %out to i8*
; CHECK-NEXT:   call void @llvm.memset.p0i8.i64(i8* %[[soz46]], i8 0, i64 %[[soz45]], i1 false)
; CHECK-NEXT:   br label %end
; CHECK: flat.scale:                                       ; preds = %flat.scale, %flat
; CHECK-NEXT:   %k = phi i64 [ 0, %flat ], [ %k.next, %flat.scale ]
; CHECK-NEXT:   %out.k = getelementptr inbounds double, double* %out, i64 %k
; CHECK-NEXT:   %[[soz47:.+]] = load double, double* %out.k, align 8
; CHECK-NEXT:   %scaled.k = fmul double %scale, %[[soz47]]
; CHECK-NEXT:   store double %scaled.k, double* %out.k, align 8
; CHECK-NEXT:   %k.next = add nuw nsw i64 %k, 1
; CHECK-NEXT:   %[[soz48:.+]] = icmp eq i64 %k.next, %total
; CHECK-NEXT:   br i1 %[[soz48]], label %end, label %flat.scale
; CHECK: col:                                              ; preds = %col.end, %init
; CHECK-NEXT:   %j = phi i64 [ 0, %init ], [ %j.next, %col.end ]
; CHECK-NEXT:   %j.next = add nuw nsw i64 %j, 1
; CHECK-NEXT:   %[[soz28:.+]] = icmp slt i64 %j.next, %m
; CHECK-NEXT:   %[[soz29:.+]] = select i1 %[[soz28]], i64 %j.next, i64 %m
; CHECK-NEXT:   %last = select i1 %upper, i64 %[[soz29]], i64 %m
; CHECK-NEXT:   %[[soz30:.+]] = icmp slt i64 %j, %m
; CHECK-NEXT:   %[[soz31:.+]] = select i1 %[[soz30]], i64 %j, i64 %m
; CHECK-NEXT:   %first = select i1 %lower, i64 %[[soz31]], i64 0
; CHECK-NEXT:   %col.offset = mul nuw nsw i64 %j, %ld
; CHECK-NEXT:   %[[soz32:.+]] = icmp slt i64 %first, %last
; CHECK-NEXT:   br i1 %[[soz32]], label %row, label %col.end
; CHECK: row:                                              ; preds = %row, %col
; CHECK-NEXT:   %i = phi i64 [ %first, %col ], [ %i.next, %row ]
; CHECK-NEXT:   %[[soz33:.+]] = add nuw nsw i64 %i, %col.offset
; CHECK-NEXT:   %out.i = getelementptr inbounds double, double* %out, i64 %[[soz33]]
; CHECK-NEXT:   %[[soz34:.+]] = load double, double* %out.i, align 8
; CHECK-NEXT:   %scaled = fmul double %scale, %[[soz34]]
; CHECK-NEXT:   %[[soz35:.+]] = select i1 %overwrite, double 0.000000e+00, double %scaled
; CHECK-NEXT:   store double %[[soz35]], double* %out.i, align 8
; CHECK-NEXT:   %i.next = add nuw nsw i64 %i, 1
; CHECK-NEXT:   %[[soz36:.+]] = icmp eq i64 %i.next, %last
; CHECK-NEXT:   br i1 %[[soz36]], label %col.end, label %row
; CHECK: col.end:                                          ; preds = %row, %col
; CHECK-NEXT:   %[[soz37:.+]] = icmp eq i64 %j.next, %n
; CHECK-NEXT:   br i1 %[[soz37]], label %end, label %col
; CHECK: end:                                              ; preds = %col.end, %flat.scale, %flat.zero, %entry
; CHECK-NEXT:   ret void
; CHECK-NEXT: }
