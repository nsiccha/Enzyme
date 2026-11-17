;RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -S -enzyme-detect-readthrow=0 | FileCheck %s; fi
;RUN: %opt < %s %newLoadEnzyme -passes="enzyme" -S -enzyme-detect-readthrow=0 | FileCheck %s

declare void @dgemm_64_(i8* nocapture readonly, i8* nocapture readonly, i8* nocapture readonly, i8* nocapture readonly, i8* nocapture readonly, i8* nocapture readonly, i8*, i8* nocapture readonly, i8*, i8* nocapture readonly, i8* nocapture readonly, i8*, i8* nocapture readonly, i64, i64) 

define void @f(i8* %C, i8* %A, i8* %B) {
entry:
  %transa = alloca i8, align 1
  %transb = alloca i8, align 1
  %m = alloca i64, align 16
  %m_p = bitcast i64* %m to i8*
  %n = alloca i64, align 16
  %n_p = bitcast i64* %n to i8*
  %k = alloca i64, align 16
  %k_p = bitcast i64* %k to i8*
  %alpha = alloca double, align 16
  %alpha_p = bitcast double* %alpha to i8*
  %lda = alloca i64, align 16
  %lda_p = bitcast i64* %lda to i8*
  %ldb = alloca i64, align 16
  %ldb_p = bitcast i64* %ldb to i8*
  %beta = alloca double, align 16
  %beta_p = bitcast double* %beta to i8*
  %ldc = alloca i64, align 16
  %ldc_p = bitcast i64* %ldc to i8*
  store i8 78, i8* %transa, align 1
  store i8 78, i8* %transb, align 1
  store i64 4, i64* %m, align 16
  store i64 4, i64* %n, align 16
  store i64 8, i64* %k, align 16
  store double 1.000000e+00, double* %alpha, align 16
  store i64 4, i64* %lda, align 16
  store i64 8, i64* %ldb, align 16
  store double 0.000000e+00, double* %beta
  store i64 4, i64* %ldc, align 16
  call void @dgemm_64_(i8* %transa, i8* %transb, i8* %m_p, i8* %n_p, i8* %k_p, i8* %alpha_p, i8* %A, i8* %lda_p, i8* %B, i8* %ldb_p, i8* %beta_p, i8* %C, i8* %ldc_p, i64 1, i64 1) 
  ret void
}

declare dso_local void @__enzyme_autodiff(...)

define void @active(i8* %C, i8* %dC, i8* %A, i8* %dA, i8* %B, i8* %dB) {
entry:
  call void (...) @__enzyme_autodiff(void (i8*,i8*,i8*)* @f, metadata !"enzyme_dup", i8* %C, i8* %dC, metadata !"enzyme_dup", i8* %A, i8* %dA, metadata !"enzyme_dup", i8* %B, i8* %dB)
  ret void
}

; CHECK: define internal void @diffef(i8* %C, i8* %"C'", i8* %A, i8* %"A'", i8* %B, i8* %"B'")
; CHECK-NEXT: entry:
; CHECK-DAG:   %ret = alloca double
; CHECK-DAG:   %byref.transpose.transa = alloca i8
; CHECK-DAG:   %byref.transpose.transb = alloca i8
; CHECK-DAG:   %byref.int.one = alloca i64
; CHECK-DAG:   %[[byref_fp_1:.+]] = alloca double
; CHECK-DAG:   %[[byref_fp_1_0:.+]] = alloca double
; CHECK-DAG:   %transa = alloca i8, align 1
; CHECK-DAG:   %transb = alloca i8, align 1
; CHECK-DAG:   %m = alloca i64, align 16
; CHECK-DAG:   %m_p = bitcast i64* %m to i8*
; CHECK-DAG:   %n = alloca i64, align 16
; CHECK-DAG:   %n_p = bitcast i64* %n to i8*
; CHECK-DAG:   %k = alloca i64, align 16
; CHECK-DAG:   %k_p = bitcast i64* %k to i8*
; CHECK-DAG:   %alpha = alloca double, align 16
; CHECK-DAG:   %alpha_p = bitcast double* %alpha to i8*
; CHECK-DAG:   %lda = alloca i64, align 16
; CHECK-DAG:   %lda_p = bitcast i64* %lda to i8*
; CHECK-DAG:   %ldb = alloca i64, align 16
; CHECK-DAG:   %ldb_p = bitcast i64* %ldb to i8*
; CHECK-DAG:   %beta = alloca double, align 16
; CHECK-DAG:   %beta_p = bitcast double* %beta to i8*
; CHECK-DAG:   %ldc = alloca i64, align 16
; CHECK-DAG:   %ldc_p = bitcast i64* %ldc to i8*
; CHECK-NEXT:   store i8 78, i8* %transa, align 1
; CHECK-NEXT:   store i8 78, i8* %transb, align 1
; CHECK-NEXT:   store i64 4, i64* %m, align 16
; CHECK-NEXT:   store i64 4, i64* %n, align 16
; CHECK-NEXT:   store i64 8, i64* %k, align 16
; CHECK-NEXT:   store double 1.000000e+00, double* %alpha, align 16
; CHECK-NEXT:   store i64 4, i64* %lda, align 16
; CHECK-NEXT:   store i64 8, i64* %ldb, align 16
; CHECK-NEXT:   store double 0.000000e+00, double* %beta
; CHECK-NEXT:   store i64 4, i64* %ldc, align 16
; CHECK-NEXT:   call void @dgemm_64_(i8* %transa, i8* %transb, i8* %m_p, i8* %n_p, i8* %k_p, i8* %alpha_p, i8* %A, i8* %lda_p, i8* %B, i8* %ldb_p, i8* %beta_p, i8* %C, i8* %ldc_p, i64 1, i64 1)
; CHECK-NEXT:   br label %invertentry

; CHECK: invertentry:                                      ; preds = %entry
; CHECK-NEXT:   store i64 1, i64* %byref.int.one
; CHECK-NEXT:   %ld.transb = load i8, i8* %transb
; CHECK-DAG:    %[[i18:.+]] = icmp eq i8 %ld.transb, 110
; CHECK-DAG:    %[[i19:.+]] = select i1 %[[i18:.+]], i8 116, i8 78
; CHECK-DAG:    %[[i20:.+]] = icmp eq i8 %ld.transb, 78
; CHECK-DAG:    %[[i21:.+]] = select i1 %[[i20:.+]], i8 84, i8 %[[i19]]
; CHECK-DAG:    %[[i22:.+]] = icmp eq i8 %ld.transb, 116
; CHECK-DAG:    %[[i23:.+]] = select i1 %[[i22:.+]], i8 110, i8 %[[i21]]
; CHECK-DAG:    %[[i24:.+]] = icmp eq i8 %ld.transb, 84
; CHECK-DAG:    %[[i25:.+]] = select i1 %[[i24:.+]], i8 78, i8 %[[i23]]
; CHECK-NEXT:   store i8 %[[i25]], i8* %byref.transpose.transb
; CHECK-NEXT:   %ld.row.trans = load i8, i8* %transa, align 1
; CHECK-NEXT:   %[[a16:.+]] = icmp eq i8 %ld.row.trans, 110
; CHECK-NEXT:   %[[a17:.+]] = icmp eq i8 %ld.row.trans, 78
; CHECK-NEXT:   %[[a18:.+]] = or i1 %[[a17]], %[[a16]]
; CHECK-NEXT:   %[[a19:.+]] = select i1 %[[a18]], i8* %transa, i8* %transb
; CHECK-NEXT:   %[[a20:.+]] = select i1 %[[a18]], i8* %byref.transpose.transb, i8* %transa
; CHECK-NEXT:   %[[a21:.+]] = select i1 %[[a18]], i8* %m_p, i8* %k_p
; CHECK-NEXT:   %[[a22:.+]] = select i1 %[[a18]], i8* %k_p, i8* %m_p
; CHECK-NEXT:   %ld.row.trans1 = load i8, i8* %transa, align 1
; CHECK-NEXT:   %[[a23:.+]] = icmp eq i8 %ld.row.trans1, 110
; CHECK-NEXT:   %[[a24:.+]] = icmp eq i8 %ld.row.trans1, 78
; CHECK-NEXT:   %[[a25:.+]] = or i1 %[[a24]], %[[a23]]
; CHECK-NEXT:   %[[a26:.+]] = select i1 %[[a25]], i8* %"C'", i8* %B
; CHECK-NEXT:   %[[a27:.+]] = select i1 %[[a25]], i8* %ldc_p, i8* %ldb_p
; CHECK-NEXT:   %[[a28:.+]] = select i1 %[[a25]], i8* %B, i8* %"C'"
; CHECK-NEXT:   %[[a29:.+]] = select i1 %[[a25]], i8* %ldb_p, i8* %ldc_p
; CHECK-NEXT:   store double 1.000000e+00, double* %[[byref_fp_1]], align 8
; CHECK-NEXT:   %[[fpcast_1:.+]] = bitcast double* %[[byref_fp_1]] to i8*
; CHECK-NEXT:   call void @dgemm_64_(i8* %[[a19]], i8* %[[a20]], i8* %[[a21]], i8* %[[a22]], i8* %n_p, i8* %alpha_p, i8* %[[a26]], i8* %[[a27]], i8* %[[a28]], i8* %[[a29]], i8* %[[fpcast_1]], i8* %"A'", i8* %lda_p, i64 1, i64 1)
; CHECK-NEXT:   %ld.transa = load i8, i8* %transa
; CHECK-DAG:    %[[i10:.+]] = icmp eq i8 %ld.transa, 110
; CHECK-DAG:    %[[i11:.+]] = select i1 %[[i10]], i8 116, i8 78
; CHECK-DAG:    %[[i12:.+]] = icmp eq i8 %ld.transa, 78
; CHECK-DAG:    %[[i13:.+]] = select i1 %[[i12]], i8 84, i8 %[[i11]]
; CHECK-DAG:    %[[i14:.+]] = icmp eq i8 %ld.transa, 116
; CHECK-DAG:    %[[i15:.+]] = select i1 %[[i14]], i8 110, i8 %[[i13]]
; CHECK-DAG:    %[[i16:.+]] = icmp eq i8 %ld.transa, 84
; CHECK-DAG:    %[[i17:.+]] = select i1 %[[i16]], i8 78, i8 %[[i15]]
; CHECK-NEXT:   store i8 %[[i17]], i8* %byref.transpose.transa
; CHECK-NEXT:   %[[ld_row_trans2:.+]] = load i8, i8* %transb, align 1
; CHECK-NEXT:   %[[a30:.+]] = icmp eq i8 %[[ld_row_trans2]], 110
; CHECK-NEXT:   %[[a31:.+]] = icmp eq i8 %[[ld_row_trans2]], 78
; CHECK-NEXT:   %[[a32:.+]] = or i1 %[[a31]], %[[a30]]
; CHECK-NEXT:   %[[a33:.+]] = select i1 %[[a32]], i8* %byref.transpose.transa, i8* %transb
; CHECK-NEXT:   %[[a34:.+]] = select i1 %[[a32]], i8* %transb, i8* %transa
; CHECK-NEXT:   %[[a35:.+]] = select i1 %[[a32]], i8* %k_p, i8* %n_p
; CHECK-NEXT:   %[[a36:.+]] = select i1 %[[a32]], i8* %n_p, i8* %k_p
; CHECK-NEXT:   %[[ld_row_trans3:.+]] = load i8, i8* %transb, align 1
; CHECK-NEXT:   %[[a37:.+]] = icmp eq i8 %[[ld_row_trans3]], 110
; CHECK-NEXT:   %[[a38:.+]] = icmp eq i8 %[[ld_row_trans3]], 78
; CHECK-NEXT:   %[[a39:.+]] = or i1 %[[a38]], %[[a37]]
; CHECK-NEXT:   %[[a40:.+]] = select i1 %[[a39]], i8* %A, i8* %"C'"
; CHECK-NEXT:   %[[a41:.+]] = select i1 %[[a39]], i8* %lda_p, i8* %ldc_p
; CHECK-NEXT:   %[[a42:.+]] = select i1 %[[a39]], i8* %"C'", i8* %A
; CHECK-NEXT:   %[[a43:.+]] = select i1 %[[a39]], i8* %ldc_p, i8* %lda_p
; CHECK-NEXT:   store double 1.000000e+00, double* %[[byref_fp_1_0]], align 8
; CHECK-NEXT:   %[[fpcast_1_0:.+]] = bitcast double* %[[byref_fp_1_0]] to i8*
; CHECK-NEXT:   call void @dgemm_64_(i8* %[[a33]], i8* %[[a34]], i8* %[[a35]], i8* %[[a36]], i8* %m_p, i8* %alpha_p, i8* %[[a40]], i8* %[[a41]], i8* %[[a42]], i8* %[[a43]], i8* %[[fpcast_1_0]], i8* %"B'", i8* %ldb_p, i64 1, i64 1)
; CHECK-NEXT:   %[[soz1:.+]] = bitcast i8* %n_p to i64*
; CHECK-NEXT:   %[[soz2:.+]] = load i64, i64* %[[soz1]], align 4
; CHECK-NEXT:   %[[soz3:.+]] = bitcast i8* %m_p to i64*
; CHECK-NEXT:   %[[soz4:.+]] = load i64, i64* %[[soz3]], align 4
; CHECK-NEXT:   %[[soz5:.+]] = bitcast i8* %ldc_p to i64*
; CHECK-NEXT:   %[[soz6:.+]] = load i64, i64* %[[soz5]], align 4
; CHECK-NEXT:   %[[soz7:.+]] = bitcast i8* %beta_p to double*
; CHECK-NEXT:   %[[soz8:.+]] = load double, double* %[[soz7]], align 8
; CHECK-NEXT:   %[[soz9:.+]] = bitcast i8* %"C'" to double*
; CHECK-NEXT:   %identity.i = fcmp oeq double %[[soz8]], 1.000000e+00
; CHECK-NEXT:   %[[soz10:.+]] = icmp sle i64 %[[soz2]], 0
; CHECK-NEXT:   %[[soz11:.+]] = icmp sle i64 %[[soz4]], 0
; CHECK-NEXT:   %[[soz12:.+]] = or i1 %[[soz11]], %[[soz10]]
; CHECK-NEXT:   %[[soz13:.+]] = or i1 %[[soz12]], %identity.i
; CHECK-NEXT:   br i1 %[[soz13]], label %__enzyme_scale_or_zero_double_64.exit, label %init.i
; CHECK: init.i:                                           ; preds = %invertentry
; CHECK-NEXT:   %overwrite.i = fcmp oeq double %[[soz8]], 0.000000e+00
; CHECK-NEXT:   %[[soz24:.+]] = icmp eq i64 %[[soz6]], %[[soz4]]
; CHECK-NEXT:   br i1 %[[soz24]], label %flat.i, label %col.i
; CHECK: flat.i:                                           ; preds = %init.i
; CHECK-NEXT:   %total.i = mul nuw nsw i64 %[[soz4]], %[[soz2]]
; CHECK-NEXT:   br i1 %overwrite.i, label %flat.zero.i, label %flat.scale.i
; CHECK: flat.zero.i:                                      ; preds = %flat.i
; CHECK-NEXT:   %[[soz25:.+]] = mul nuw nsw i64 %total.i, 8
; CHECK-NEXT:   call void @llvm.memset.p0i8.i64(i8* %"C'", i8 0, i64 %[[soz25]], i1 false)
; CHECK-NEXT:   br label %__enzyme_scale_or_zero_double_64.exit
; CHECK: flat.scale.i:                                     ; preds = %flat.scale.i, %flat.i
; CHECK-NEXT:   %k.i = phi i64 [ 0, %flat.i ], [ %k.next.i, %flat.scale.i ]
; CHECK-NEXT:   %out.k.i = getelementptr inbounds double, double* %[[soz9]], i64 %k.i
; CHECK-NEXT:   %[[soz26:.+]] = load double, double* %out.k.i, align 8
; CHECK-NEXT:   %scaled.k.i = fmul double %[[soz8]], %[[soz26]]
; CHECK-NEXT:   store double %scaled.k.i, double* %out.k.i, align 8
; CHECK-NEXT:   %k.next.i = add nuw nsw i64 %k.i, 1
; CHECK-NEXT:   %[[soz27:.+]] = icmp eq i64 %k.next.i, %total.i
; CHECK-NEXT:   br i1 %[[soz27]], label %__enzyme_scale_or_zero_double_64.exit, label %flat.scale.i
; CHECK: col.i:                                            ; preds = %col.end.i, %init.i
; CHECK-NEXT:   %j.i = phi i64 [ 0, %init.i ], [ %j.next.i, %col.end.i ]
; CHECK-NEXT:   %j.next.i = add nuw nsw i64 %j.i, 1
; CHECK-NEXT:   %[[soz14:.+]] = icmp slt i64 %j.next.i, %[[soz4]]
; CHECK-NEXT:   %[[soz15:.+]] = select i1 %[[soz14]], i64 %j.next.i, i64 %[[soz4]]
; CHECK-NEXT:   %[[soz16:.+]] = icmp slt i64 %j.i, %[[soz4]]
; CHECK-NEXT:   %[[soz17:.+]] = select i1 %[[soz16]], i64 %j.i, i64 %[[soz4]]
; CHECK-NEXT:   %col.offset.i = mul nuw nsw i64 %j.i, %[[soz6]]
; CHECK-NEXT:   %[[soz18:.+]] = icmp slt i64 0, %[[soz4]]
; CHECK-NEXT:   br i1 %[[soz18]], label %row.i, label %col.end.i
; CHECK: row.i:                                            ; preds = %row.i, %col.i
; CHECK-NEXT:   %i.i = phi i64 [ 0, %col.i ], [ %i.next.i, %row.i ]
; CHECK-NEXT:   %[[soz19:.+]] = add nuw nsw i64 %i.i, %col.offset.i
; CHECK-NEXT:   %out.i.i = getelementptr inbounds double, double* %[[soz9]], i64 %[[soz19]]
; CHECK-NEXT:   %[[soz20:.+]] = load double, double* %out.i.i, align 8
; CHECK-NEXT:   %scaled.i = fmul double %[[soz8]], %[[soz20]]
; CHECK-NEXT:   %[[soz21:.+]] = select i1 %overwrite.i, double 0.000000e+00, double %scaled.i
; CHECK-NEXT:   store double %[[soz21]], double* %out.i.i, align 8
; CHECK-NEXT:   %i.next.i = add nuw nsw i64 %i.i, 1
; CHECK-NEXT:   %[[soz22:.+]] = icmp eq i64 %i.next.i, %[[soz4]]
; CHECK-NEXT:   br i1 %[[soz22]], label %col.end.i, label %row.i
; CHECK: col.end.i:                                        ; preds = %row.i, %col.i
; CHECK-NEXT:   %[[soz23:.+]] = icmp eq i64 %j.next.i, %[[soz2]]
; CHECK-NEXT:   br i1 %[[soz23]], label %__enzyme_scale_or_zero_double_64.exit, label %col.i
; CHECK: __enzyme_scale_or_zero_double_64.exit:            ; preds = %invertentry, %flat.zero.i, %flat.scale.i, %col.end.i
; CHECK-NEXT:   ret void
; CHECK-NEXT: }
