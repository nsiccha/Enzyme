;RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -enzyme-blas-copy=1 -enzyme-lapack-copy=1 -enzyme-detect-readthrow=0 -S | FileCheck %s; fi
;RUN: %opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-blas-copy=1 -enzyme-lapack-copy=1 -enzyme-detect-readthrow=0 -S | FileCheck %s

; y := x. In reverse mode dx += dy and then dy := 0: y is overwritten, so
; nothing before the copy depends on what its adjoint holds. Without the second
; step an earlier write to y would receive the adjoint of this one as well, and
; a shadow of y that is used again keeps growing.
; With a constant x only the second step is left.

;                       n,                      x,   incx,                   y,   incy
declare void @dcopy_64_(i8* nocapture readonly, i8*, i8* nocapture readonly, i8*, i8* nocapture readonly)

define void @f(i8* noalias %n, i8* noalias %x, i8* noalias %y) {
entry:
  %incx = alloca i64, align 16
  %incx_p = bitcast i64* %incx to i8*
  %incy = alloca i64, align 16
  %incy_p = bitcast i64* %incy to i8*
  store i64 1, i64* %incx, align 16
  store i64 2, i64* %incy, align 16
  call void @dcopy_64_(i8* %n, i8* %x, i8* %incx_p, i8* %y, i8* %incy_p)
  ret void
}

declare dso_local void @__enzyme_autodiff(...)

define void @active(i8* %n, i8* %x, i8* %dx, i8* %y, i8* %dy) {
entry:
  call void (...) @__enzyme_autodiff(void (i8*,i8*,i8*)* @f, metadata !"enzyme_const", i8* %n, metadata !"enzyme_dup", i8* %x, i8* %dx, metadata !"enzyme_dup", i8* %y, i8* %dy)
  ret void
}

define void @g(i8* noalias %n, i8* noalias %x, i8* noalias %y) {
entry:
  %incx = alloca i64, align 16
  %incx_p = bitcast i64* %incx to i8*
  %incy = alloca i64, align 16
  %incy_p = bitcast i64* %incy to i8*
  store i64 1, i64* %incx, align 16
  store i64 2, i64* %incy, align 16
  call void @dcopy_64_(i8* %n, i8* %x, i8* %incx_p, i8* %y, i8* %incy_p)
  ret void
}

define void @constant_source(i8* %n, i8* %x, i8* %y, i8* %dy) {
entry:
  call void (...) @__enzyme_autodiff(void (i8*,i8*,i8*)* @g, metadata !"enzyme_const", i8* %n, metadata !"enzyme_const", i8* %x, metadata !"enzyme_dup", i8* %y, i8* %dy)
  ret void
}

; CHECK: define internal void @diffef(i8* noalias %n, i8* noalias %x, i8* %"x'", i8* noalias %y, i8* %"y'")
; CHECK-NEXT: entry:
; CHECK-NEXT:   %ret = alloca double, align 8
; CHECK-NEXT:   %byref.int.one = alloca i64, align 8
; CHECK-NEXT:   %byref.constant.fp.1.0 = alloca double, align 8
; CHECK-NEXT:   %incx = alloca i64, align 16
; CHECK-NEXT:   %incx_p = bitcast i64* %incx to i8*
; CHECK-NEXT:   %incy = alloca i64, align 16
; CHECK-NEXT:   %incy_p = bitcast i64* %incy to i8*
; CHECK-NEXT:   store i64 1, i64* %incx, align 16
; CHECK-NEXT:   store i64 2, i64* %incy, align 16
; CHECK-NEXT:   call void @dcopy_64_(i8* %n, i8* %x, i8* %incx_p, i8* %y, i8* %incy_p)
; CHECK-NEXT:   br label %invertentry
; CHECK: invertentry:                                      ; preds = %entry
; CHECK-NEXT:   store i64 1, i64* %byref.int.one, align 4
; CHECK-NEXT:   store double 1.000000e+00, double* %byref.constant.fp.1.0, align 8
; CHECK-NEXT:   call void @daxpy_64_(i8* %n, double* %byref.constant.fp.1.0, i8* %"y'", i8* %incy_p, i8* %"x'", i8* %incx_p)
; CHECK-NEXT:   %[[soz1:.+]] = bitcast i8* %n to i64*
; CHECK-NEXT:   %[[soz2:.+]] = load i64, i64* %[[soz1]], align 4
; CHECK-NEXT:   %[[soz3:.+]] = bitcast i8* %incy_p to i64*
; CHECK-NEXT:   %[[soz4:.+]] = load i64, i64* %[[soz3]], align 4
; CHECK-NEXT:   %[[soz5:.+]] = sub i64 0, %[[soz4]]
; CHECK-NEXT:   %[[soz6:.+]] = icmp slt i64 %[[soz4]], 0
; CHECK-NEXT:   %[[soz7:.+]] = select i1 %[[soz6]], i64 %[[soz5]], i64 %[[soz4]]
; CHECK-NEXT:   %[[soz8:.+]] = bitcast i8* %"y'" to double*
; CHECK-NEXT:   %[[soz9:.+]] = icmp sle i64 %[[soz2]], 0
; CHECK-NEXT:   br i1 %[[soz9]], label %__enzyme_scale_or_zero_double_64.exit, label %init.i
; CHECK: init.i:                                           ; preds = %invertentry
; CHECK-NEXT:   %[[soz31:.+]] = icmp eq i64 %[[soz7]], 1
; CHECK-NEXT:   br i1 %[[soz31]], label %flat.i, label %col.i
; CHECK: flat.i:                                           ; preds = %init.i
; CHECK-NEXT:   %[[soz32:.+]] = mul nuw nsw i64 %[[soz2]], 8
; CHECK-NEXT:   call void @llvm.memset.p0i8.i64(i8* %"y'", i8 0, i64 %[[soz32]], i1 false)
; CHECK-NEXT:   br label %__enzyme_scale_or_zero_double_64.exit
; CHECK: col.i:                                            ; preds = %col.end.i, %init.i
; CHECK-NEXT:   %j.i = phi i64 [ 0, %init.i ], [ %j.next.i, %col.end.i ]
; CHECK-NEXT:   %j.next.i = add nuw nsw i64 %j.i, 1
; CHECK-NEXT:   %[[soz10:.+]] = icmp slt i64 %j.i, 1
; CHECK-NEXT:   %[[soz11:.+]] = select i1 %[[soz10]], i64 %j.i, i64 1
; CHECK-NEXT:   %col.offset.i = mul nuw nsw i64 %j.i, %[[soz7]]
; CHECK-NEXT:   br label %row.i
; CHECK: row.i:                                            ; preds = %row.i, %col.i
; CHECK-NEXT:   %i.i = phi i64 [ 0, %col.i ], [ %i.next.i, %row.i ]
; CHECK-NEXT:   %[[soz12:.+]] = add nuw nsw i64 %i.i, %col.offset.i
; CHECK-NEXT:   %out.i.i = getelementptr inbounds double, double* %[[soz8]], i64 %[[soz12]]
; CHECK-NEXT:   %[[soz13:.+]] = load double, double* %out.i.i, align 8
; CHECK-NEXT:   %scaled.i = fmul double 0.000000e+00, %[[soz13]]
; CHECK-NEXT:   store double 0.000000e+00, double* %out.i.i, align 8
; CHECK-NEXT:   %i.next.i = add nuw nsw i64 %i.i, 1
; CHECK-NEXT:   %[[soz14:.+]] = icmp eq i64 %i.next.i, 1
; CHECK-NEXT:   br i1 %[[soz14]], label %col.end.i, label %row.i
; CHECK: col.end.i:                                        ; preds = %row.i
; CHECK-NEXT:   %[[soz15:.+]] = icmp eq i64 %j.next.i, %[[soz2]]
; CHECK-NEXT:   br i1 %[[soz15]], label %__enzyme_scale_or_zero_double_64.exit, label %col.i
; CHECK: __enzyme_scale_or_zero_double_64.exit:            ; preds = %invertentry, %flat.i, %col.end.i
; CHECK-NEXT:   ret void
; CHECK-NEXT: }

; CHECK: define internal void @diffeg(i8* noalias %n, i8* noalias %x, i8* noalias %y, i8* %"y'")
; CHECK-NEXT: entry:
; CHECK-NEXT:   %ret = alloca double, align 8
; CHECK-NEXT:   %byref.int.one = alloca i64, align 8
; CHECK-NEXT:   %incx = alloca i64, align 16
; CHECK-NEXT:   %incx_p = bitcast i64* %incx to i8*
; CHECK-NEXT:   %incy = alloca i64, align 16
; CHECK-NEXT:   %incy_p = bitcast i64* %incy to i8*
; CHECK-NEXT:   store i64 1, i64* %incx, align 16
; CHECK-NEXT:   store i64 2, i64* %incy, align 16
; CHECK-NEXT:   call void @dcopy_64_(i8* %n, i8* %x, i8* %incx_p, i8* %y, i8* %incy_p)
; CHECK-NEXT:   br label %invertentry
; CHECK: invertentry:                                      ; preds = %entry
; CHECK-NEXT:   store i64 1, i64* %byref.int.one, align 4
; CHECK-NEXT:   %[[soz16:.+]] = bitcast i8* %n to i64*
; CHECK-NEXT:   %[[soz17:.+]] = load i64, i64* %[[soz16]], align 4
; CHECK-NEXT:   %[[soz18:.+]] = bitcast i8* %incy_p to i64*
; CHECK-NEXT:   %[[soz19:.+]] = load i64, i64* %[[soz18]], align 4
; CHECK-NEXT:   %[[soz20:.+]] = sub i64 0, %[[soz19]]
; CHECK-NEXT:   %[[soz21:.+]] = icmp slt i64 %[[soz19]], 0
; CHECK-NEXT:   %[[soz22:.+]] = select i1 %[[soz21]], i64 %[[soz20]], i64 %[[soz19]]
; CHECK-NEXT:   %[[soz23:.+]] = bitcast i8* %"y'" to double*
; CHECK-NEXT:   %[[soz24:.+]] = icmp sle i64 %[[soz17]], 0
; CHECK-NEXT:   br i1 %[[soz24]], label %__enzyme_scale_or_zero_double_64.exit, label %init.i
; CHECK: init.i:                                           ; preds = %invertentry
; CHECK-NEXT:   %[[soz33:.+]] = icmp eq i64 %[[soz7]], 1
; CHECK-NEXT:   br i1 %[[soz33]], label %flat.i, label %col.i
; CHECK: flat.i:                                           ; preds = %init.i
; CHECK-NEXT:   %[[soz34:.+]] = mul nuw nsw i64 %[[soz2]], 8
; CHECK-NEXT:   call void @llvm.memset.p0i8.i64(i8* %"y'", i8 0, i64 %[[soz34]], i1 false)
; CHECK-NEXT:   br label %__enzyme_scale_or_zero_double_64.exit
; CHECK: col.i:                                            ; preds = %col.end.i, %init.i
; CHECK-NEXT:   %j.i = phi i64 [ 0, %init.i ], [ %j.next.i, %col.end.i ]
; CHECK-NEXT:   %j.next.i = add nuw nsw i64 %j.i, 1
; CHECK-NEXT:   %[[soz25:.+]] = icmp slt i64 %j.i, 1
; CHECK-NEXT:   %[[soz26:.+]] = select i1 %[[soz25]], i64 %j.i, i64 1
; CHECK-NEXT:   %col.offset.i = mul nuw nsw i64 %j.i, %[[soz22]]
; CHECK-NEXT:   br label %row.i
; CHECK: row.i:                                            ; preds = %row.i, %col.i
; CHECK-NEXT:   %i.i = phi i64 [ 0, %col.i ], [ %i.next.i, %row.i ]
; CHECK-NEXT:   %[[soz27:.+]] = add nuw nsw i64 %i.i, %col.offset.i
; CHECK-NEXT:   %out.i.i = getelementptr inbounds double, double* %[[soz23]], i64 %[[soz27]]
; CHECK-NEXT:   %[[soz28:.+]] = load double, double* %out.i.i, align 8
; CHECK-NEXT:   %scaled.i = fmul double 0.000000e+00, %[[soz28]]
; CHECK-NEXT:   store double 0.000000e+00, double* %out.i.i, align 8
; CHECK-NEXT:   %i.next.i = add nuw nsw i64 %i.i, 1
; CHECK-NEXT:   %[[soz29:.+]] = icmp eq i64 %i.next.i, 1
; CHECK-NEXT:   br i1 %[[soz29]], label %col.end.i, label %row.i
; CHECK: col.end.i:                                        ; preds = %row.i
; CHECK-NEXT:   %[[soz30:.+]] = icmp eq i64 %j.next.i, %[[soz17]]
; CHECK-NEXT:   br i1 %[[soz30]], label %__enzyme_scale_or_zero_double_64.exit, label %col.i
; CHECK: __enzyme_scale_or_zero_double_64.exit:            ; preds = %invertentry, %flat.i, %col.end.i
; CHECK-NEXT:   ret void
; CHECK-NEXT: }
