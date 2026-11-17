; RUN: if [ %llvmver -lt 16 ] && [ %llvmver -ge 14 ] ; then %opt < %s %loadEnzyme -opaque-pointers -enzyme -enzyme-preopt=false -mem2reg -early-cse -instsimplify -jump-threading -adce -S | FileCheck %s; fi
; RUN: if [ %llvmver -ge 14 ]; then %opt < %s %newLoadEnzyme -opaque-pointers -passes="enzyme,function(mem2reg,early-cse,instsimplify,jump-threading,adce)" -enzyme-preopt=false -S | FileCheck %s ; fi

; ModuleID = '../examples/big/big_inlined_correctness.cpp'
source_filename = "../examples/big/big_inlined_correctness.cpp"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.Prod = type { ptr, double }

declare i32 @dgemm_(ptr nocapture noundef readonly %transa_t, ptr nocapture noundef readonly %transb_t, ptr nocapture noundef readonly %m, ptr nocapture noundef readonly %n, ptr nocapture noundef readonly %k, ptr nocapture noundef readonly %alpha, ptr nocapture noundef readonly %a, ptr nocapture noundef readonly %lda, ptr nocapture noundef readonly %b, ptr nocapture noundef readonly %ldb, ptr nocapture noundef readonly %beta, ptr nocapture noundef %c, ptr nocapture noundef readonly %ldc, i32, i32)

; Function Attrs: mustprogress noinline nounwind uwtable
define dso_local void @_Z3mulR4ProdPd(ptr nocapture noundef nonnull align 8 dereferenceable(16) %P, ptr noalias nocapture noundef readonly %rhs) {
entry:
  %N = alloca i8, align 1
  %ten = alloca i32, align 4
  %one = alloca double, align 8
  %zero = alloca double, align 8
  %calloc = call dereferenceable_or_null(32) ptr @calloc(i64 1, i64 32)
  store i8 78, ptr %N, align 1
  store i32 2, ptr %ten, align 4
  store double 1.000000e+00, ptr %one, align 8
  store double 0.000000e+00, ptr %zero, align 8
  %call1 = call i32 @dgemm_(ptr noundef nonnull %N, ptr noundef nonnull %N, ptr noundef nonnull %ten, ptr noundef nonnull %ten, ptr noundef nonnull %ten, ptr noundef nonnull %one, ptr noundef %rhs, ptr noundef nonnull %ten, ptr noundef %rhs, ptr noundef nonnull %ten, ptr noundef nonnull %one, ptr noundef %calloc, ptr noundef nonnull %ten, i32 1, i32 1)
  %0 = load ptr, ptr %P, align 8
  %call2 = call i32 @dgemm_(ptr noundef nonnull %N, ptr noundef nonnull %N, ptr noundef nonnull %ten, ptr noundef nonnull %ten, ptr noundef nonnull %ten, ptr noundef nonnull %one, ptr noundef %calloc, ptr noundef nonnull %ten, ptr noundef %rhs, ptr noundef nonnull %ten, ptr noundef nonnull %zero, ptr noundef %0, ptr noundef nonnull %ten, i32 1, i32 1)
  %alpha = getelementptr inbounds %struct.Prod, ptr %P, i64 0, i32 1
  store double 0.000000e+00, ptr %alpha, align 8
  ret void
}

declare noalias ptr @malloc(i64)

; Function Attrs: mustprogress nounwind uwtable
define dso_local double @_Z8simulatePd(ptr nocapture noundef readonly %P) {
entry:
  %M = alloca %struct.Prod, align 8
  %call = tail call noalias dereferenceable_or_null(32) ptr @malloc(i64 noundef 32) 
  store ptr %call, ptr %M, align 8
  %alpha = getelementptr inbounds %struct.Prod, ptr %M, i64 0, i32 1
  store double 1.000000e+00, ptr %alpha, align 8
  call void @_Z3mulR4ProdPd(ptr noundef nonnull align 8 dereferenceable(16) %M, ptr noundef %P)
  %0 = load ptr, ptr %M, align 8
  %1 = load double, ptr %0, align 8
  ret double %1
}

define void @caller(ptr %A, ptr %Adup) {
entry:
  call void (...) @_Z17__enzyme_autodiffz(ptr noundef nonnull @_Z8simulatePd, metadata !"enzyme_dup", ptr noundef nonnull %A, ptr noundef nonnull %Adup)
  ret void
}

declare void @_Z17__enzyme_autodiffz(...) 

declare noalias noundef ptr @calloc(i64 noundef, i64 noundef)

; we must actually save or set the matmul
; CHECK: define internal void @diffe_Z3mulR4ProdPd(ptr nocapture align 8 %P, ptr nocapture align 8 %"P'", ptr noalias nocapture readonly %rhs, ptr nocapture %"rhs'", { ptr, ptr, ptr } %tapeArg)
; CHECK-NEXT: invertentry:
; CHECK-NEXT:   %byref.transpose.transb = alloca i8, align 1
; CHECK-NEXT:   %byref.constant.fp.1.0 = alloca double, align 8
; CHECK-NEXT:   %byref.transpose.transa = alloca i8, align 1
; CHECK-NEXT:   %byref.constant.fp.1.04 = alloca double, align 8
; CHECK-NEXT:   %byref.transpose.transb8 = alloca i8, align 1
; CHECK-NEXT:   %byref.constant.fp.1.011 = alloca double, align 8
; CHECK-NEXT:   %byref.transpose.transa13 = alloca i8, align 1
; CHECK-NEXT:   %byref.constant.fp.1.016 = alloca double, align 8
; CHECK-NEXT:   %malloccall = alloca i8, i64 1, align 1
; CHECK-NEXT:   %malloccall2 = alloca double, i64 1, align 8
; CHECK-NEXT:   %malloccall1 = alloca i32, i64 1, align 4
; CHECK-NEXT:   %"calloc'mi" = extractvalue { ptr, ptr, ptr } %tapeArg, 1
; CHECK-NEXT:   %calloc = extractvalue { ptr, ptr, ptr } %tapeArg, 2
; CHECK-NEXT:   store i8 78, ptr %malloccall, align 1
; CHECK-NEXT:   store i32 2, ptr %malloccall1, align 4
; CHECK-NEXT:   store double 1.000000e+00, ptr %malloccall2, align 8
; CHECK-NEXT:   %"'il_phi" = extractvalue { ptr, ptr, ptr } %tapeArg, 0
; CHECK-NEXT:   %"alpha'ipg" = getelementptr inbounds %struct.Prod, ptr %"P'", i64 0, i32 1
; CHECK-NEXT:   store double 0.000000e+00, ptr %"alpha'ipg", align 8
; CHECK-NEXT:   %ld.transb = load i8, ptr %malloccall, align 1
; CHECK-NEXT:   %[[i2:.+]] = icmp eq i8 %ld.transb, 110
; CHECK-NEXT:   %[[i3:.+]] = select i1 %[[i2]], i8 116, i8 78
; CHECK-NEXT:   %[[i4:.+]] = icmp eq i8 %ld.transb, 78
; CHECK-NEXT:   %[[i5:.+]] = select i1 %[[i4]], i8 84, i8 %[[i3]]
; CHECK-NEXT:   %[[i6:.+]] = icmp eq i8 %ld.transb, 116
; CHECK-NEXT:   %[[i7:.+]] = select i1 %[[i6]], i8 110, i8 %[[i5]]
; CHECK-NEXT:   %[[i8:.+]] = icmp eq i8 %ld.transb, 84
; CHECK-NEXT:   %[[i9:.+]] = select i1 %[[i8]], i8 78, i8 %[[i7]]
; CHECK-NEXT:   store i8 %[[i9]], ptr %byref.transpose.transb, align 1
; CHECK-NEXT:   %ld.row.trans = load i8, ptr %malloccall, align 1
; CHECK-NEXT:   %[[i10:.+]] = icmp eq i8 %ld.row.trans, 110
; CHECK-NEXT:   %[[i11:.+]] = icmp eq i8 %ld.row.trans, 78
; CHECK-NEXT:   %[[i12:.+]] = or i1 %[[i11]], %[[i10]]
; CHECK-NEXT:   %[[i13:.+]] = select i1 %[[i12]], ptr %byref.transpose.transb, ptr %malloccall
; CHECK-NEXT:   %[[i14:.+]] = select i1 %[[i12]], ptr %"'il_phi", ptr %rhs
; CHECK-NEXT:   %[[i15:.+]] = select i1 %[[i12]], ptr %rhs, ptr %"'il_phi"
; CHECK-NEXT:   store double 1.000000e+00, ptr %byref.constant.fp.1.0, align 8
; CHECK-NEXT:   call void @dgemm_(ptr %malloccall, ptr %[[i13]], ptr %malloccall1, ptr %malloccall1, ptr %malloccall1, ptr %malloccall2, ptr %[[i14]], ptr %malloccall1, ptr %[[i15]], ptr %malloccall1, ptr %byref.constant.fp.1.0, ptr %"calloc'mi", ptr %malloccall1, i32 1, i32 1)
; CHECK-NEXT:   %ld.transa = load i8, ptr %malloccall, align 1
; CHECK-NEXT:   %[[i16:.+]] = icmp eq i8 %ld.transa, 110
; CHECK-NEXT:   %[[i17:.+]] = select i1 %[[i16]], i8 116, i8 78
; CHECK-NEXT:   %[[i18:.+]] = icmp eq i8 %ld.transa, 78
; CHECK-NEXT:   %[[i19:.+]] = select i1 %[[i18]], i8 84, i8 %[[i17]]
; CHECK-NEXT:   %[[i20:.+]] = icmp eq i8 %ld.transa, 116
; CHECK-NEXT:   %[[i21:.+]] = select i1 %[[i20]], i8 110, i8 %[[i19]]
; CHECK-NEXT:   %[[i22:.+]] = icmp eq i8 %ld.transa, 84
; CHECK-NEXT:   %[[i23:.+]] = select i1 %[[i22]], i8 78, i8 %[[i21]]
; CHECK-NEXT:   store i8 %[[i23]], ptr %byref.transpose.transa, align 1
; CHECK-NEXT:   %ld.row.trans2 = load i8, ptr %malloccall, align 1
; CHECK-NEXT:   %[[i24:.+]] = icmp eq i8 %ld.row.trans2, 110
; CHECK-NEXT:   %[[i25:.+]] = icmp eq i8 %ld.row.trans2, 78
; CHECK-NEXT:   %[[i26:.+]] = or i1 %[[i25]], %[[i24]]
; CHECK-NEXT:   %[[i27:.+]] = select i1 %[[i26]], ptr %byref.transpose.transa, ptr %malloccall
; CHECK-NEXT:   %[[i28:.+]] = select i1 %[[i26]], ptr %calloc, ptr %"'il_phi"
; CHECK-NEXT:   %[[i29:.+]] = select i1 %[[i26]], ptr %"'il_phi", ptr %calloc
; CHECK-NEXT:   store double 1.000000e+00, ptr %byref.constant.fp.1.04, align 8
; CHECK-NEXT:   call void @dgemm_(ptr %[[i27]], ptr %malloccall, ptr %malloccall1, ptr %malloccall1, ptr %malloccall1, ptr %malloccall2, ptr %[[i28]], ptr %malloccall1, ptr %[[i29]], ptr %malloccall1, ptr %byref.constant.fp.1.04, ptr %"rhs'", ptr %malloccall1, i32 1, i32 1)
; CHECK-NEXT:   %[[soz1:.+]] = load i32, ptr %malloccall1, align 4
; CHECK-NEXT:   %[[soz2:.+]] = icmp sle i32 %[[soz1]], 0
; CHECK-NEXT:   br i1 %[[soz2]], label %__enzyme_scale_or_zero_double_32.exit, label %flat.zero.i
; CHECK: flat.zero.i:                                      ; preds = %invertentry
; CHECK-NEXT:   %total.i = mul nuw nsw i32 %[[soz1]], %[[soz1]]
; CHECK-NEXT:   %[[soz45:.+]] = mul nuw nsw i32 %total.i, 8
; CHECK-NEXT:   call void @llvm.memset.p0.i32(ptr %"'il_phi", i8 0, i32 %[[soz45]], i1 false)
; CHECK-NEXT:   br label %__enzyme_scale_or_zero_double_32.exit
; CHECK: flat.scale.i:                                     ; preds = %flat.scale.i
; CHECK-NEXT:   %out.k.i = getelementptr inbounds double, ptr %"'il_phi", i32 %k.next.i
; CHECK-NEXT:   %[[soz46:.+]] = load double, ptr %out.k.i, align 8
; CHECK-NEXT:   %scaled.k.i = fmul double 0.000000e+00, %[[soz46]]
; CHECK-NEXT:   store double %scaled.k.i, ptr %out.k.i, align 8
; CHECK-NEXT:   %k.next.i = add nuw nsw i32 %k.next.i, 1
; CHECK-NEXT:   br label %flat.scale.i
; CHECK: col.i:                                            ; preds = %col.end.i
; CHECK-NEXT:   %j.next.i = add nuw nsw i32 %j.next.i, 1
; CHECK-NEXT:   %col.offset.i = mul nuw nsw i32 %j.next.i, %[[soz1]]
; CHECK-NEXT:   %[[soz47:.+]] = icmp slt i32 0, %[[soz1]]
; CHECK-NEXT:   br i1 %[[soz47]], label %row.i, label %col.end.i
; CHECK: row.i:                                            ; preds = %row.i, %col.i
; CHECK-NEXT:   %i.i = phi i32 [ 0, %col.i ], [ %i.next.i, %row.i ]
; CHECK-NEXT:   %[[soz4:.+]] = add nuw nsw i32 %i.i, %col.offset.i
; CHECK-NEXT:   %out.i.i = getelementptr inbounds double, ptr %"'il_phi", i32 %[[soz4]]
; CHECK-NEXT:   store double 0.000000e+00, ptr %out.i.i, align 8
; CHECK-NEXT:   %i.next.i = add nuw nsw i32 %i.i, 1
; CHECK-NEXT:   %[[soz5:.+]] = icmp eq i32 %i.next.i, %[[soz1]]
; CHECK-NEXT:   br i1 %[[soz5]], label %col.end.i, label %row.i
; CHECK: col.end.i:                                        ; preds = %row.i, %col.i
; CHECK-NEXT:   %[[soz6:.+]] = icmp eq i32 %j.next.i, %[[soz1]]
; CHECK-NEXT:   br i1 %[[soz6]], label %__enzyme_scale_or_zero_double_32.exit, label %col.i
; CHECK: __enzyme_scale_or_zero_double_32.exit:            ; preds = %invertentry, %flat.zero.i, %col.end.i
; CHECK-NEXT:   %ld.transb7 = load i8, ptr %malloccall, align 1
; CHECK-NEXT:   %[[soz7:.+]] = icmp eq i8 %ld.transb7, 110
; CHECK-NEXT:   %[[soz8:.+]] = select i1 %[[soz7]], i8 116, i8 78
; CHECK-NEXT:   %[[soz9:.+]] = icmp eq i8 %ld.transb7, 78
; CHECK-NEXT:   %[[soz10:.+]] = select i1 %[[soz9]], i8 84, i8 %[[soz8]]
; CHECK-NEXT:   %[[soz11:.+]] = icmp eq i8 %ld.transb7, 116
; CHECK-NEXT:   %[[soz12:.+]] = select i1 %[[soz11]], i8 110, i8 %[[soz10]]
; CHECK-NEXT:   %[[soz13:.+]] = icmp eq i8 %ld.transb7, 84
; CHECK-NEXT:   %[[soz14:.+]] = select i1 %[[soz13]], i8 78, i8 %[[soz12]]
; CHECK-NEXT:   store i8 %[[soz14]], ptr %byref.transpose.transb8, align 1
; CHECK-NEXT:   %ld.row.trans9 = load i8, ptr %malloccall, align 1
; CHECK-NEXT:   %[[soz15:.+]] = icmp eq i8 %ld.row.trans9, 110
; CHECK-NEXT:   %[[soz16:.+]] = icmp eq i8 %ld.row.trans9, 78
; CHECK-NEXT:   %[[soz17:.+]] = or i1 %[[soz16]], %[[soz15]]
; CHECK-NEXT:   %[[soz18:.+]] = select i1 %[[soz17]], ptr %byref.transpose.transb8, ptr %malloccall
; CHECK-NEXT:   %[[soz19:.+]] = select i1 %[[soz17]], ptr %"calloc'mi", ptr %rhs
; CHECK-NEXT:   %[[soz20:.+]] = select i1 %[[soz17]], ptr %rhs, ptr %"calloc'mi"
; CHECK-NEXT:   store double 1.000000e+00, ptr %byref.constant.fp.1.011, align 8
; CHECK-NEXT:   call void @dgemm_(ptr %malloccall, ptr %[[soz18]], ptr %malloccall1, ptr %malloccall1, ptr %malloccall1, ptr %malloccall2, ptr %[[soz19]], ptr %malloccall1, ptr %[[soz20]], ptr %malloccall1, ptr %byref.constant.fp.1.011, ptr %"rhs'", ptr %malloccall1, i32 1, i32 1)
; CHECK-NEXT:   %ld.transa12 = load i8, ptr %malloccall, align 1
; CHECK-NEXT:   %[[soz21:.+]] = icmp eq i8 %ld.transa12, 110
; CHECK-NEXT:   %[[soz22:.+]] = select i1 %[[soz21]], i8 116, i8 78
; CHECK-NEXT:   %[[soz23:.+]] = icmp eq i8 %ld.transa12, 78
; CHECK-NEXT:   %[[soz24:.+]] = select i1 %[[soz23]], i8 84, i8 %[[soz22]]
; CHECK-NEXT:   %[[soz25:.+]] = icmp eq i8 %ld.transa12, 116
; CHECK-NEXT:   %[[soz26:.+]] = select i1 %[[soz25]], i8 110, i8 %[[soz24]]
; CHECK-NEXT:   %[[soz27:.+]] = icmp eq i8 %ld.transa12, 84
; CHECK-NEXT:   %[[soz28:.+]] = select i1 %[[soz27]], i8 78, i8 %[[soz26]]
; CHECK-NEXT:   store i8 %[[soz28]], ptr %byref.transpose.transa13, align 1
; CHECK-NEXT:   %ld.row.trans14 = load i8, ptr %malloccall, align 1
; CHECK-NEXT:   %[[soz29:.+]] = icmp eq i8 %ld.row.trans14, 110
; CHECK-NEXT:   %[[soz30:.+]] = icmp eq i8 %ld.row.trans14, 78
; CHECK-NEXT:   %[[soz31:.+]] = or i1 %[[soz30]], %[[soz29]]
; CHECK-NEXT:   %[[soz32:.+]] = select i1 %[[soz31]], ptr %byref.transpose.transa13, ptr %malloccall
; CHECK-NEXT:   %[[soz33:.+]] = select i1 %[[soz31]], ptr %rhs, ptr %"calloc'mi"
; CHECK-NEXT:   %[[soz34:.+]] = select i1 %[[soz31]], ptr %"calloc'mi", ptr %rhs
; CHECK-NEXT:   store double 1.000000e+00, ptr %byref.constant.fp.1.016, align 8
; CHECK-NEXT:   call void @dgemm_(ptr %[[soz32]], ptr %malloccall, ptr %malloccall1, ptr %malloccall1, ptr %malloccall1, ptr %malloccall2, ptr %[[soz33]], ptr %malloccall1, ptr %[[soz34]], ptr %malloccall1, ptr %byref.constant.fp.1.016, ptr %"rhs'", ptr %malloccall1, i32 1, i32 1)
; CHECK-NEXT:   %[[soz35:.+]] = load i32, ptr %malloccall1, align 4
; CHECK-NEXT:   %[[soz36:.+]] = load double, ptr %malloccall2, align 8
; CHECK-NEXT:   %identity.i17 = fcmp oeq double %[[soz36]], 1.000000e+00
; CHECK-NEXT:   %[[soz37:.+]] = icmp sle i32 %[[soz35]], 0
; CHECK-NEXT:   %[[soz38:.+]] = or i1 %[[soz37]], %identity.i17
; CHECK-NEXT:   br i1 %[[soz38]], label %__enzyme_scale_or_zero_double_32.exit38, label %flat.i21
; CHECK: flat.i21:                                         ; preds = %__enzyme_scale_or_zero_double_32.exit
; CHECK-NEXT:   %overwrite.i18 = fcmp oeq double %[[soz36]], 0.000000e+00
; CHECK-NEXT:   %total.i20 = mul nuw nsw i32 %[[soz35]], %[[soz35]]
; CHECK-NEXT:   br i1 %overwrite.i18, label %flat.zero.i22, label %flat.scale.i27
; CHECK: flat.zero.i22:                                    ; preds = %flat.i21
; CHECK-NEXT:   %[[soz48:.+]] = mul nuw nsw i32 %total.i20, 8
; CHECK-NEXT:   call void @llvm.memset.p0.i32(ptr %"calloc'mi", i8 0, i32 %[[soz48]], i1 false)
; CHECK-NEXT:   br label %__enzyme_scale_or_zero_double_32.exit38
; CHECK: flat.scale.i27:                                   ; preds = %flat.scale.i27, %flat.i21
; CHECK-NEXT:   %k.i23 = phi i32 [ 0, %flat.i21 ], [ %k.next.i26, %flat.scale.i27 ]
; CHECK-NEXT:   %out.k.i24 = getelementptr inbounds double, ptr %"calloc'mi", i32 %k.i23
; CHECK-NEXT:   %[[soz49:.+]] = load double, ptr %out.k.i24, align 8
; CHECK-NEXT:   %scaled.k.i25 = fmul double %[[soz36]], %[[soz49]]
; CHECK-NEXT:   store double %scaled.k.i25, ptr %out.k.i24, align 8
; CHECK-NEXT:   %k.next.i26 = add nuw nsw i32 %k.i23, 1
; CHECK-NEXT:   %[[soz50:.+]] = icmp eq i32 %k.next.i26, %total.i20
; CHECK-NEXT:   br i1 %[[soz50]], label %__enzyme_scale_or_zero_double_32.exit38, label %flat.scale.i27
; CHECK: col.i31:                                          ; preds = %col.end.i37
; CHECK-NEXT:   %j.next.i29 = add nuw nsw i32 %j.next.i29, 1
; CHECK-NEXT:   %col.offset.i30 = mul nuw nsw i32 %j.next.i29, %[[soz35]]
; CHECK-NEXT:   %[[soz51:.+]] = icmp slt i32 0, %[[soz35]]
; CHECK-NEXT:   br i1 %[[soz51]], label %row.i36, label %col.end.i37
; CHECK: row.i36:                                          ; preds = %row.i36, %col.i31
; CHECK-NEXT:   %i.i32 = phi i32 [ 0, %col.i31 ], [ %i.next.i35, %row.i36 ]
; CHECK-NEXT:   %[[soz52:.+]] = add nuw nsw i32 %i.i32, %col.offset.i30
; CHECK-NEXT:   %out.i.i33 = getelementptr inbounds double, ptr %"calloc'mi", i32 %[[soz52]]
; CHECK-NEXT:   %[[soz53:.+]] = load double, ptr %out.i.i33, align 8
; CHECK-NEXT:   %scaled.i34 = fmul double %[[soz36]], %[[soz53]]
; CHECK-NEXT:   %[[soz54:.+]] = select i1 %overwrite.i18, double 0.000000e+00, double %scaled.i34
; CHECK-NEXT:   store double %[[soz54]], ptr %out.i.i33, align 8
; CHECK-NEXT:   %i.next.i35 = add nuw nsw i32 %i.i32, 1
; CHECK-NEXT:   %[[soz55:.+]] = icmp eq i32 %i.next.i35, %[[soz35]]
; CHECK-NEXT:   br i1 %[[soz55]], label %col.end.i37, label %row.i36
; CHECK: col.end.i37:                                      ; preds = %row.i36, %col.i31
; CHECK-NEXT:   %[[soz56:.+]] = icmp eq i32 %j.next.i29, %[[soz35]]
; CHECK-NEXT:   br i1 %[[soz56]], label %__enzyme_scale_or_zero_double_32.exit38, label %col.i31
; CHECK: __enzyme_scale_or_zero_double_32.exit38:          ; preds = %__enzyme_scale_or_zero_double_32.exit, %flat.zero.i22, %flat.scale.i27, %col.end.i37
; CHECK-NEXT:   call void @free(ptr nonnull %"calloc'mi")
; CHECK-NEXT:   call void @free(ptr %calloc)
; CHECK-NEXT:   ret void
; CHECK-NEXT: }
