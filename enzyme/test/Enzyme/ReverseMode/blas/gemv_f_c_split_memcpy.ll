;RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -enzyme-blas-copy=0 -enzyme-lapack-copy=1 -S -enzyme-detect-readthrow=0 | FileCheck %s; fi
;RUN: %opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-blas-copy=0  -enzyme-lapack-copy=1 -S -enzyme-detect-readthrow=0 | FileCheck %s

;                       trans,                  M,                       N,                     alpha,                  A,    lda,                    x,  , incx,                  beta,                    y,  incy
declare void @dgemv_64_(i8* nocapture readonly, i8* nocapture readonly, i8* nocapture readonly, i8* nocapture readonly, i8* , i8* nocapture readonly, i8*, i8* nocapture readonly, i8* nocapture readonly, i8* , i8* nocapture readonly, i64) 

define void @f(i8* noalias %y, i8* noalias %A, i8* noalias %x) {
entry:
  %transa = alloca i8, align 1
  %m = alloca i64, align 16
  %m_p = bitcast i64* %m to i8*
  %n = alloca i64, align 16
  %n_p = bitcast i64* %n to i8*
  %alpha = alloca double, align 16
  %alpha_p = bitcast double* %alpha to i8*
  %lda = alloca i64, align 16
  %lda_p = bitcast i64* %lda to i8*
  %incx = alloca i64, align 16
  %incx_p = bitcast i64* %incx to i8*
  %beta = alloca double, align 16
  %beta_p = bitcast double* %beta to i8*
  %incy = alloca i64, align 16
  %incy_p = bitcast i64* %incy to i8*
  store i8 78, i8* %transa, align 1
  store i64 4, i64* %m, align 16
  store i64 4, i64* %n, align 16
  store double 1.000000e+00, double* %alpha, align 16
  store i64 4, i64* %lda, align 16
  store i64 2, i64* %incx, align 16
  store double 0.000000e+00, double* %beta
  store i64 1, i64* %incy, align 16
  call void @dgemv_64_(i8* %transa, i8* %m_p, i8* %n_p, i8* %alpha_p, i8* %A, i8* %lda_p, i8* %x, i8* %incx_p, i8* %beta_p, i8* %y, i8* %incy_p, i64 1) 
  ret void
}

define void @g(i8* noalias %y, i8* noalias %A, i8* noalias %x) {
entry:
  call void @f(i8* %y, i8* %A, i8* %x)
  %ptr = bitcast i8* %x to double*
  store double 0.0000000e+00, double* %ptr, align 8
  ret void
}

declare dso_local void @__enzyme_autodiff(...)

define void @active(i8* %y, i8* %dy, i8* %A, i8* %dA, i8* %x, i8* %dx) {
entry:
  call void (...) @__enzyme_autodiff(void (i8*,i8*,i8*)* @g, metadata !"enzyme_dup", i8* %y, i8* %dy, metadata !"enzyme_dup", i8* %A, i8* %dA, metadata !"enzyme_dup", i8* %x, i8* %dx)
  ret void
}

; CHECK: define internal double* @augmented_f(i8* noalias %y, i8* %"y'", i8* noalias %A, i8* %"A'", i8* noalias %x, i8* %"x'")
; CHECK-NEXT: entry:
; CHECK-NEXT:   %0 = alloca double*
; CHECK-NEXT:   %incy = alloca i64, i64 1, align 16
; CHECK-NEXT:   %1 = bitcast i64* %incy to i8*
; CHECK-NEXT:   %beta = alloca double, i64 1, align 16
; CHECK-NEXT:   %2 = bitcast double* %beta to i8*
; CHECK-NEXT:   %incx = alloca i64, i64 1, align 16
; CHECK-NEXT:   %3 = bitcast i64* %incx to i8*
; CHECK-NEXT:   %lda = alloca i64, i64 1, align 16
; CHECK-NEXT:   %4 = bitcast i64* %lda to i8*
; CHECK-NEXT:   %alpha = alloca double, i64 1, align 16
; CHECK-NEXT:   %5 = bitcast double* %alpha to i8*
; CHECK-NEXT:   %n = alloca i64, i64 1, align 16
; CHECK-NEXT:   %6 = bitcast i64* %n to i8*
; CHECK-NEXT:   %m = alloca i64, i64 1, align 16
; CHECK-NEXT:   %7 = bitcast i64* %m to i8*
; CHECK-NEXT:   %malloccall = alloca i8, i64 1, align 1
; CHECK-NEXT:   %8 = bitcast i8* %7 to i64*, !enzyme_caststack !5
; CHECK-NEXT:   %m_p = bitcast i64* %8 to i8*
; CHECK-NEXT:   %9 = bitcast i8* %6 to i64*, !enzyme_caststack !5
; CHECK-NEXT:   %n_p = bitcast i64* %9 to i8*
; CHECK-NEXT:   %10 = bitcast i8* %5 to double*, !enzyme_caststack !5
; CHECK-NEXT:   %alpha_p = bitcast double* %10 to i8*
; CHECK-NEXT:   %11 = bitcast i8* %4 to i64*, !enzyme_caststack !5
; CHECK-NEXT:   %lda_p = bitcast i64* %11 to i8*
; CHECK-NEXT:   %12 = bitcast i8* %3 to i64*, !enzyme_caststack !5
; CHECK-NEXT:   %incx_p = bitcast i64* %12 to i8*
; CHECK-NEXT:   %13 = bitcast i8* %2 to double*, !enzyme_caststack !5
; CHECK-NEXT:   %beta_p = bitcast double* %13 to i8*
; CHECK-NEXT:   %14 = bitcast i8* %1 to i64*, !enzyme_caststack !5
; CHECK-NEXT:   %incy_p = bitcast i64* %14 to i8*
; CHECK-NEXT:   store i8 78, i8* %malloccall, align 1
; CHECK-NEXT:   store i64 4, i64* %8, align 16
; CHECK-NEXT:   store i64 4, i64* %9, align 16
; CHECK-NEXT:   store double 1.000000e+00, double* %10, align 16
; CHECK-NEXT:   store i64 4, i64* %11, align 16
; CHECK-NEXT:   store i64 2, i64* %12, align 16
; CHECK-NEXT:   store double 0.000000e+00, double* %13
; CHECK-NEXT:   store i64 1, i64* %14, align 16
; CHECK-NEXT:   %loaded.trans = load i8, i8* %malloccall
; CHECK-DAG:   %[[i15:.+]] = icmp eq i8 %loaded.trans, 78
; CHECK-DAG:   %[[i16:.+]] = icmp eq i8 %loaded.trans, 110
; CHECK-NEXT:   %17 = or i1 %[[i16]], %[[i15]]
; CHECK-NEXT:   %18 = select i1 %17, i8* %n_p, i8* %m_p
; CHECK-NEXT:   %19 = bitcast i8* %18 to i64*
; CHECK-NEXT:   %20 = load i64, i64* %19
; CHECK-NEXT:   %mallocsize = mul nuw nsw i64 %20, 8
; CHECK-NEXT:   %malloccall8 = tail call noalias nonnull i8* @malloc(i64 %mallocsize)
; CHECK-NEXT:   %cache.x = bitcast i8* %malloccall8 to double*
; CHECK-NEXT:   store double* %cache.x, double** %0
; CHECK-NEXT:   %21 = bitcast i8* %incx_p to i64*
; CHECK-NEXT:   %22 = load i64, i64* %21
; CHECK-NEXT:   %23 = bitcast i8* %x to double*
; CHECK:   %24 = icmp eq i64 %20, 0
; CHECK-NEXT:   br i1 %24, label %__enzyme_memcpy_double_64_da0sa0stride.exit, label %init.idx.i

; CHECK: init.idx.i:                                       ; preds = %entry
; CHECK-NEXT:   %a.i = sub nsw i64 1, %20
; CHECK-NEXT:   %negidx.i = mul nsw i64 %a.i, %22
; CHECK-NEXT:   %is.neg.i = icmp slt i64 %22, 0
; CHECK-NEXT:   %startidx.i = select i1 %is.neg.i, i64 %negidx.i, i64 0
; CHECK-NEXT:   br label %for.body.i

; CHECK: for.body.i:                                       ; preds = %for.body.i, %init.idx.i
; CHECK-NEXT:   %idx.i = phi i64 [ 0, %init.idx.i ], [ %idx.next.i, %for.body.i ]
; CHECK-NEXT:   %sidx.i = phi i64 [ %startidx.i, %init.idx.i ], [ %sidx.next.i, %for.body.i ]
; CHECK-NEXT:   %dst.i.i = getelementptr inbounds double, double* %cache.x, i64 %idx.i
; CHECK-NEXT:   %src.i.i = getelementptr inbounds double, double* %23, i64 %sidx.i
; CHECK-NEXT:   %src.i.l.i = load double, double* %src.i.i
; CHECK-NEXT:   store double %src.i.l.i, double* %dst.i.i
; CHECK-NEXT:   %idx.next.i = add nsw i64 %idx.i, 1
; CHECK-NEXT:   %sidx.next.i = add nsw i64 %sidx.i, %22
; CHECK-NEXT:   %25 = icmp eq i64 %20, %idx.next.i
; CHECK-NEXT:   br i1 %25, label %__enzyme_memcpy_double_64_da0sa0stride.exit, label %for.body.i

; CHECK: __enzyme_memcpy_double_64_da0sa0stride.exit:      ; preds = %entry, %for.body.i
; CHECK-NEXT:   call void @dgemv_64_(i8* %malloccall, i8* %m_p, i8* %n_p, i8* %alpha_p, i8* %A, i8* %lda_p, i8* %x, i8* %incx_p, i8* %beta_p, i8* %y, i8* %incy_p, i64 1)
; CHECK-NEXT:   %26 = load double*, double** %0
; CHECK-NEXT:   ret double* %26
; CHECK-NEXT: }

; CHECK: define internal void @diffef(i8* noalias %y, i8* %"y'", i8* noalias %A, i8* %"A'", i8* noalias %x, i8* %"x'", double* 
; CHECK-NEXT: entry:
; CHECK-NEXT:   %ret = alloca double
; CHECK-NEXT:   %byref.int.one = alloca i64
; CHECK-NEXT:   %byref.transpose.transa = alloca i8
; CHECK-NEXT:   %byref.constant.char.N = alloca i8
; CHECK-NEXT:   %byref.constant.fp.1.0 = alloca double
; CHECK-NEXT:   %incy = alloca i64, i64 1, align 16
; CHECK-NEXT:   %1 = bitcast i64* %incy to i8*
; CHECK-NEXT:   %beta = alloca double, i64 1, align 16
; CHECK-NEXT:   %2 = bitcast double* %beta to i8*
; CHECK-NEXT:   %incx = alloca i64, i64 1, align 16
; CHECK-NEXT:   %3 = bitcast i64* %incx to i8*
; CHECK-NEXT:   %lda = alloca i64, i64 1, align 16
; CHECK-NEXT:   %4 = bitcast i64* %lda to i8*
; CHECK-NEXT:   %alpha = alloca double, i64 1, align 16
; CHECK-NEXT:   %5 = bitcast double* %alpha to i8*
; CHECK-NEXT:   %n = alloca i64, i64 1, align 16
; CHECK-NEXT:   %6 = bitcast i64* %n to i8*
; CHECK-NEXT:   %m = alloca i64, i64 1, align 16
; CHECK-NEXT:   %7 = bitcast i64* %m to i8*
; CHECK-NEXT:   %malloccall = alloca i8, i64 1, align 1
; CHECK-NEXT:   %8 = bitcast i8* %7 to i64*, !enzyme_caststack !5
; CHECK-NEXT:   %m_p = bitcast i64* %8 to i8*
; CHECK-NEXT:   %9 = bitcast i8* %6 to i64*, !enzyme_caststack !5
; CHECK-NEXT:   %n_p = bitcast i64* %9 to i8*
; CHECK-NEXT:   %10 = bitcast i8* %5 to double*, !enzyme_caststack !5
; CHECK-NEXT:   %alpha_p = bitcast double* %10 to i8*
; CHECK-NEXT:   %11 = bitcast i8* %4 to i64*, !enzyme_caststack !5
; CHECK-NEXT:   %lda_p = bitcast i64* %11 to i8*
; CHECK-NEXT:   %12 = bitcast i8* %3 to i64*, !enzyme_caststack !5
; CHECK-NEXT:   %incx_p = bitcast i64* %12 to i8*
; CHECK-NEXT:   %13 = bitcast i8* %2 to double*, !enzyme_caststack !5
; CHECK-NEXT:   %beta_p = bitcast double* %13 to i8*
; CHECK-NEXT:   %14 = bitcast i8* %1 to i64*, !enzyme_caststack !5
; CHECK-NEXT:   %incy_p = bitcast i64* %14 to i8*
; CHECK-NEXT:   store i8 78, i8* %malloccall, align 1
; CHECK-NEXT:   store i64 4, i64* %8, align 16
; CHECK-NEXT:   store i64 4, i64* %9, align 16
; CHECK-NEXT:   store double 1.000000e+00, double* %10, align 16
; CHECK-NEXT:   store i64 4, i64* %11, align 16
; CHECK-NEXT:   store i64 2, i64* %12, align 16
; CHECK-NEXT:   store double 0.000000e+00, double* %13
; CHECK-NEXT:   store i64 1, i64* %14, align 16
; CHECK-NEXT:   br label %invertentry

; CHECK: invertentry:                                      ; preds = %entry
; CHECK-NEXT:   %15 = bitcast double* %0 to i8*
; CHECK-NEXT:   store i64 1, i64* %byref.int.one
; CHECK-NEXT:   %ld.row.trans = load i8, i8* %malloccall, align 1
; CHECK-DAG:   %[[r24:.+]] = icmp eq i8 %ld.row.trans, 110
; CHECK-DAG:   %[[r25:.+]] = icmp eq i8 %ld.row.trans, 78
; CHECK-DAG:   %[[r26:.+]] = or i1 %[[r25]], %[[r24]]
; CHECK-NEXT:   %[[r27:.+]] = select i1 %[[r26]], i8* %"y'", i8* %15
; CHECK-NEXT:   %[[cast1:.+]] = bitcast i64* %byref.int.one to i8*
; CHECK-NEXT:   %[[r31:.+]] = select i1 %[[r26]], i8* %incy_p, i8* %[[cast1]]
; CHECK-NEXT:   %[[r35:.+]] = select i1 %[[r26]], i8* %15, i8* %"y'"
; CHECK-NEXT:   %[[cast2:.+]] = bitcast i8* %incy_p to i64*
; CHECK-NEXT:   %[[r39:.+]] = select i1 %[[r26]], i64* %byref.int.one, i64* %[[cast2]]
; CHECK-NEXT:   call void @dger_64_(i8* %m_p, i8* %n_p, i8* %alpha_p, i8* %[[r27]], i8* %[[r31]], i8* %[[r35]], i64* %[[r39]], i8* %"A'", i8* %lda_p)
; CHECK-NEXT:   %ld.transa = load i8, i8* %malloccall
; CHECK-DAG:    %[[r0:.+]] = icmp eq i8 %ld.transa, 110
; CHECK-DAG:    %[[r1:.+]] = select i1 %[[r0]], i8 116, i8 78
; CHECK-DAG:    %[[r2:.+]] = icmp eq i8 %ld.transa, 78
; CHECK-DAG:    %[[r3:.+]] = select i1 %[[r2]], i8 84, i8 %[[r1]]
; CHECK-DAG:    %[[r4:.+]] = icmp eq i8 %ld.transa, 116
; CHECK-DAG:    %[[r5:.+]] = select i1 %[[r4]], i8 110, i8 %[[r3]]
; CHECK-DAG:    %[[r6:.+]] = icmp eq i8 %ld.transa, 84
; CHECK-DAG:    %[[r7:.+]] = select i1 %[[r6]], i8 78, i8 %[[r5]]
; CHECK-NEXT:   store i8 %[[r7]], i8* %byref.transpose.transa
; CHECK-NEXT:   store i8 78, i8* %byref.constant.char.N, align 1
; CHECK-NEXT:   store double 1.000000e+00, double* %byref.constant.fp.1.0
; CHECK-NEXT:   %fpcast.constant.fp.1.0 = bitcast double* %byref.constant.fp.1.0 to i8*
; CHECK-NEXT:   call void @dgemv_64_(i8* %byref.transpose.transa, i8* %m_p, i8* %n_p, i8* %alpha_p, i8* %A, i8* %lda_p, i8* %"y'", i8* %incy_p, i8* %fpcast.constant.fp.1.0, i8* %"x'", i8* %incx_p, i64 1)
; CHECK-NEXT:   %ld.row.trans1 = load i8, i8* %malloccall
; CHECK-DAG:    %[[r40:.+]] = icmp eq i8 %ld.row.trans1, 110
; CHECK-DAG:    %[[r41:.+]] = icmp eq i8 %ld.row.trans1, 78
; CHECK-NEXT:   %[[r42:.+]] = or i1 %[[r41]], %[[r40]]
; CHECK-NEXT:   %[[r43:.+]] = select i1 %[[r42]], i8* %m_p, i8* %n_p
; CHECK-NEXT:   %[[soz1:.+]] = bitcast i8* %[[r43]] to i64*
; CHECK-NEXT:   %[[soz2:.+]] = load i64, i64* %[[soz1]], align 4
; CHECK-NEXT:   %[[soz3:.+]] = bitcast i8* %incy_p to i64*
; CHECK-NEXT:   %[[soz4:.+]] = load i64, i64* %[[soz3]], align 4
; CHECK-NEXT:   %[[soz5:.+]] = bitcast i8* %beta_p to double*
; CHECK-NEXT:   %[[soz6:.+]] = load double, double* %[[soz5]], align 8
; CHECK-NEXT:   %[[soz7:.+]] = sub i64 0, %[[soz4]]
; CHECK-NEXT:   %[[soz8:.+]] = icmp slt i64 %[[soz4]], 0
; CHECK-NEXT:   %[[soz9:.+]] = select i1 %[[soz8]], i64 %[[soz7]], i64 %[[soz4]]
; CHECK-NEXT:   %[[soz10:.+]] = bitcast i8* %"y'" to double*
; CHECK-NEXT:   %identity.i = fcmp oeq double %[[soz6]], 1.000000e+00
; CHECK-NEXT:   %[[soz11:.+]] = icmp sle i64 %[[soz2]], 0
; CHECK-NEXT:   %[[soz12:.+]] = or i1 %[[soz11]], %identity.i
; CHECK-NEXT:   br i1 %[[soz12]], label %__enzyme_scale_or_zero_double_64.exit, label %init.i
; CHECK: init.i:                                           ; preds = %invertentry
; CHECK-NEXT:   %overwrite.i = fcmp oeq double %[[soz6]], 0.000000e+00
; CHECK-NEXT:   %[[soz20:.+]] = icmp eq i64 %[[soz9]], 1
; CHECK-NEXT:   br i1 %[[soz20]], label %flat.i, label %col.i
; CHECK: flat.i:                                           ; preds = %init.i
; CHECK-NEXT:   br i1 %overwrite.i, label %flat.zero.i, label %flat.scale.i
; CHECK: flat.zero.i:                                      ; preds = %flat.i
; CHECK-NEXT:   %[[soz21:.+]] = mul nuw nsw i64 %[[soz2]], 8
; CHECK-NEXT:   call void @llvm.memset.p0i8.i64(i8* %"y'", i8 0, i64 %[[soz21]], i1 false)
; CHECK-NEXT:   br label %__enzyme_scale_or_zero_double_64.exit
; CHECK: flat.scale.i:                                     ; preds = %flat.scale.i, %flat.i
; CHECK-NEXT:   %k.i = phi i64 [ 0, %flat.i ], [ %k.next.i, %flat.scale.i ]
; CHECK-NEXT:   %out.k.i = getelementptr inbounds double, double* %[[soz10]], i64 %k.i
; CHECK-NEXT:   %[[soz22:.+]] = load double, double* %out.k.i, align 8
; CHECK-NEXT:   %scaled.k.i = fmul double %[[soz6]], %[[soz22]]
; CHECK-NEXT:   store double %scaled.k.i, double* %out.k.i, align 8
; CHECK-NEXT:   %k.next.i = add nuw nsw i64 %k.i, 1
; CHECK-NEXT:   %[[soz23:.+]] = icmp eq i64 %k.next.i, %[[soz2]]
; CHECK-NEXT:   br i1 %[[soz23]], label %__enzyme_scale_or_zero_double_64.exit, label %flat.scale.i
; CHECK: col.i:                                            ; preds = %col.end.i, %init.i
; CHECK-NEXT:   %j.i = phi i64 [ 0, %init.i ], [ %j.next.i, %col.end.i ]
; CHECK-NEXT:   %j.next.i = add nuw nsw i64 %j.i, 1
; CHECK-NEXT:   %[[soz13:.+]] = icmp slt i64 %j.i, 1
; CHECK-NEXT:   %[[soz14:.+]] = select i1 %[[soz13]], i64 %j.i, i64 1
; CHECK-NEXT:   %col.offset.i = mul nuw nsw i64 %j.i, %[[soz9]]
; CHECK-NEXT:   br label %row.i
; CHECK: row.i:                                            ; preds = %row.i, %col.i
; CHECK-NEXT:   %i.i = phi i64 [ 0, %col.i ], [ %i.next.i, %row.i ]
; CHECK-NEXT:   %[[soz15:.+]] = add nuw nsw i64 %i.i, %col.offset.i
; CHECK-NEXT:   %out.i.i = getelementptr inbounds double, double* %[[soz10]], i64 %[[soz15]]
; CHECK-NEXT:   %[[soz16:.+]] = load double, double* %out.i.i, align 8
; CHECK-NEXT:   %scaled.i = fmul double %[[soz6]], %[[soz16]]
; CHECK-NEXT:   %[[soz17:.+]] = select i1 %overwrite.i, double 0.000000e+00, double %scaled.i
; CHECK-NEXT:   store double %[[soz17]], double* %out.i.i, align 8
; CHECK-NEXT:   %i.next.i = add nuw nsw i64 %i.i, 1
; CHECK-NEXT:   %[[soz18:.+]] = icmp eq i64 %i.next.i, 1
; CHECK-NEXT:   br i1 %[[soz18]], label %col.end.i, label %row.i
; CHECK: col.end.i:                                        ; preds = %row.i
; CHECK-NEXT:   %[[soz19:.+]] = icmp eq i64 %j.next.i, %[[soz2]]
; CHECK-NEXT:   br i1 %[[soz19]], label %__enzyme_scale_or_zero_double_64.exit, label %col.i
; CHECK: __enzyme_scale_or_zero_double_64.exit:            ; preds = %invertentry, %flat.zero.i, %flat.scale.i, %col.end.i
; CHECK-NEXT:   %[[r44:.+]] = bitcast double* %0 to i8*
; CHECK-NEXT:   tail call void @free(i8* nonnull %[[r44]])
; CHECK-NEXT:   ret void
; CHECK-NEXT: }
