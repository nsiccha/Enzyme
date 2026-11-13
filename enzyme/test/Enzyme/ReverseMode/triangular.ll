; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme-detect-readthrow=0 -enzyme -mem2reg -instsimplify -adce -loop-deletion -correlated-propagation -simplifycfg -early-cse -simplifycfg -instsimplify -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -enzyme-detect-readthrow=0 -passes="enzyme,function(mem2reg,instsimplify,adce,loop(loop-deletion),correlated-propagation,%simplifycfg,early-cse,%simplifycfg,instsimplify)" -S | FileCheck %s

; Function Attrs: noinline norecurse nounwind uwtable
define dso_local double @get(double* nocapture %x, i64 %i, i64 %j) local_unnamed_addr #0 {
entry:
  %arrayidx = getelementptr inbounds double, double* %x, i64 %i
  %0 = load double, double* %arrayidx, align 8
  ret double %0
}

; Function Attrs: noinline norecurse nounwind uwtable
define dso_local double @f(double* nocapture %x, i64 %n) #0 {
entry:
  br label %for.cond3.preheader

for.cond3.preheader:                              ; preds = %entry, %for.cond.cleanup6
  %i = phi i64 [ %i_inc, %for.cond.cleanup6 ], [ 0, %entry ]
  %outersum = phi double [ %sum.1.lcssa, %for.cond.cleanup6 ], [ 0.000000e+00, %entry ]
  %i_inc = add nuw i64 %i, 1
; note this is now technically not exactly triangular
;  %cmp423 = icmp eq i64 %i, 0
;  br i1 %cmp423, label %for.cond.cleanup6, label %for.body7
  br label %for.body7

for.body7:                                        ; preds = %for.cond3.preheader, %for.body7
  %j = phi i64 [ %j_inc, %for.body7 ], [ 0, %for.cond3.preheader ]
  %innersum = phi double [ %add, %for.body7 ], [ %outersum, %for.cond3.preheader ]
  %call = tail call fast double @get(double* %x, i64 undef, i64 %j)
  %mul = fmul fast double %call, %call
  %add = fadd fast double %mul, %innersum
  %j_inc = add nuw i64 %j, 1
  %exitcond = icmp eq i64 %j, %i
  br i1 %exitcond, label %for.cond.cleanup6, label %for.body7

for.cond.cleanup6:                                ; preds = %for.body7
  %sum.1.lcssa = phi double [ %add, %for.body7 ]
  %cmp1 = icmp eq i64 %i, %n
  br i1 %cmp1, label %return, label %for.cond3.preheader

return:                                           ; preds = %for.cond.cleanup6
  %retval.0 = phi double [ %sum.1.lcssa, %for.cond.cleanup6 ]
  ret double %retval.0
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @dsumsquare(double* %x, double* %xp, i64 %n) local_unnamed_addr #1 {
entry:
  %call = tail call fast double @__enzyme_autodiff(i8* bitcast (double (double*, i64)* @f to i8*), double* %x, double* %xp, i64 %n)
  ret double %call
}

declare dso_local double @__enzyme_autodiff(i8*, double*, double*, i64) local_unnamed_addr

attributes #0 = { noinline norecurse nounwind uwtable }
attributes #1 = { noinline nounwind uwtable }

; The first table slot owns the growing value buffer; later slots hold offsets.
; CHECK-LABEL: define internal void @diffef(double* nocapture %x, double* nocapture %"x'", i64 %n, double %differeturn)
; CHECK: entry:
; CHECK-NEXT:   %[[V0:.+]] = add nsw i64 %n, 1
; CHECK-NEXT:   %[[V1:.+]] = add i64 %[[V0]], 1
; CHECK-NEXT:   %mallocsize = mul nuw nsw i64 %[[V1]], 8
; CHECK-NEXT:   %malloccall = tail call noalias nonnull i8* @malloc(i64 %mallocsize)
; CHECK-NEXT:   %call_malloccache = bitcast i8* %malloccall to double**
; CHECK-NEXT:   store double* null, double** %call_malloccache, align 8
; CHECK-NEXT:   br label %for.cond3.preheader

; CHECK: for.cond3.preheader:
; CHECK-NEXT:   %call_capacity.0 = phi i64 [ 0, %entry ], [ %[[V11:.+]], %for.cond.cleanup6 ]
; CHECK-NEXT:   %call_used.0 = phi i64 [ 0, %entry ], [ %[[V4:.+]], %for.cond.cleanup6 ]
; CHECK-NEXT:   %iv = phi i64 [ %iv.next, %for.cond.cleanup6 ], [ 0, %entry ]
; CHECK-NEXT:   %iv.next = add{{( nsw)?}} i64 %iv, 1
; CHECK-NEXT:   %[[V2:.+]] = getelementptr inbounds double*, double** %call_malloccache, i64 %iv.next
; CHECK-NEXT:   %[[V3:.+]] = load double*, double** %call_malloccache, align 8
; CHECK-NEXT:   %[[V4]] = add nuw i64 %call_used.0, %iv.next
; CHECK-NEXT:   %[[V5:.+]] = shl i64 %call_capacity.0, 1
; CHECK-NEXT:   %[[V6:.+]] = icmp ule i64 %call_capacity.0, 1152921504606846975
; CHECK-NEXT:   %[[V7:.+]] = select i1 %[[V6]], i64 %[[V5]], i64 %[[V4]]
; CHECK-NEXT:   %[[V8:.+]] = icmp ugt i64 %[[V4]], %[[V7]]
; CHECK-NEXT:   %[[V9:.+]] = select i1 %[[V8]], i64 %[[V4]], i64 %[[V7]]
; CHECK-NEXT:   %[[V10:.+]] = icmp ugt i64 %[[V4]], %call_capacity.0
; CHECK-NEXT:   %[[V11]] = select i1 %[[V10]], i64 %[[V9]], i64 %call_capacity.0
; CHECK-NEXT:   %[[V12:.+]] = bitcast double* %[[V3]] to i8*
; CHECK-NEXT:   %[[V13:.+]] = mul nuw i64 %call_capacity.0, 8
; CHECK-NEXT:   %[[V14:.+]] = mul nuw i64 %[[V11]], 8
; CHECK-NEXT:   %[[V15:.+]] = icmp ugt i64 %[[V14]], %[[V13]]
; CHECK-NEXT:   br i1 %[[V15]], label %grow.i, label %__enzyme_grow_ragged_cache_double.exit

; CHECK: grow.i:
; CHECK-NEXT:   %[[V16:.+]] = call noalias nonnull i8* @malloc(i64 %[[V14]])
; CHECK-NEXT:   call void @llvm.memcpy.p0i8.p0i8.i64(i8* nonnull align 1 %[[V16]], i8* align 1 %[[V12]], i64 %[[V13]], i1 false)
; CHECK-NEXT:   call void @free(i8* %[[V12]])
; CHECK-NEXT:   br label %__enzyme_grow_ragged_cache_double.exit

; CHECK: __enzyme_grow_ragged_cache_double.exit:
; CHECK-NEXT:   %[[V17:.+]] = phi i8* [ %[[V12]], %for.cond3.preheader ], [ %[[V16]], %grow.i ]
; CHECK-NEXT:   %[[V18:.+]] = bitcast i8* %[[V17]] to double*
; CHECK-NEXT:   store double* %[[V18]], double** %call_malloccache, align 8
; CHECK-NEXT:   %[[V19:.+]] = inttoptr i64 %call_used.0 to double*
; CHECK-NEXT:   store double* %[[V19]], double** %[[V2]], align 8, !invariant.group ![[G0:[0-9]+]]
; CHECK-NEXT:   br label %for.body7

; CHECK: for.body7:
; CHECK-NEXT:   %iv1 = phi i64 [ %iv.next2, %for.body7 ], [ 0, %__enzyme_grow_ragged_cache_double.exit ]
; CHECK-NEXT:   %iv.next2 = add nuw nsw i64 %iv1, 1
; CHECK-NEXT:   %call = call fast double @augmented_get(double* %x, double* %"x'", i64 undef, i64 %iv1)
; CHECK-NEXT:   %[[V20:.+]] = load double*, double** %[[V2]], align 8
; CHECK-NEXT:   %[[V21:.+]] = ptrtoint double* %[[V20]] to i64
; CHECK-NEXT:   %[[V22:.+]] = load double*, double** %call_malloccache, align 8
; CHECK-NEXT:   %[[V23:.+]] = add nuw i64 %[[V21]], %iv1
; CHECK-NEXT:   %[[V24:.+]] = getelementptr inbounds double, double* %[[V22]], i64 %[[V23]]
; CHECK-NEXT:   store double %call, double* %[[V24]], align 8, !invariant.group ![[G1:[0-9]+]]
; CHECK-NEXT:   %exitcond = icmp eq i64 %iv1, %iv
; CHECK-NEXT:   br i1 %exitcond, label %for.cond.cleanup6, label %for.body7

; CHECK: for.cond.cleanup6:
; CHECK-NEXT:   %cmp1 = icmp eq i64 %iv, %n
; CHECK-NEXT:   br i1 %cmp1, label %invertfor.cond.cleanup6, label %for.cond3.preheader

; CHECK: invertentry:
; CHECK-NEXT:   %[[V25:.+]] = load double*, double** %call_malloccache, align 8
; CHECK-NEXT:   %[[V26:.+]] = bitcast double* %[[V25]] to i8*
; CHECK-NEXT:   tail call void @free(i8* %[[V26]])
; CHECK-NEXT:   tail call void @free(i8* nonnull %malloccall)
; CHECK-NEXT:   ret void

; CHECK: invertfor.cond3.preheader:
; CHECK-NEXT:   %[[V27:.+]] = icmp eq i64 %"iv'ac.0", 0
; CHECK-NEXT:   br i1 %[[V27]], label %invertentry, label %incinvertfor.cond3.preheader

; CHECK: incinvertfor.cond3.preheader:
; CHECK-NEXT:   %[[V28:.+]] = add nsw i64 %"iv'ac.0", -1
; CHECK-NEXT:   br label %invertfor.cond.cleanup6

; CHECK: invertfor.body7:
; CHECK-NEXT:   %"iv1'ac.0" = phi i64 [ %"iv'ac.0", %invertfor.cond.cleanup6 ], [ %[[V40:.+]], %incinvertfor.body7 ]
; CHECK-NEXT:   %[[V29:.+]] = add i64 %"iv'ac.0", 1
; CHECK-NEXT:   %[[V30:.+]] = getelementptr inbounds double*, double** %call_malloccache, i64 %[[V29]]
; CHECK-NEXT:   %[[V31:.+]] = load double*, double** %[[V30]], align 8
; CHECK-NEXT:   %[[V32:.+]] = ptrtoint double* %[[V31]] to i64
; CHECK-NEXT:   %[[V33:.+]] = load double*, double** %call_malloccache, align 8
; CHECK-NEXT:   %[[V34:.+]] = add nuw i64 %[[V32]], %"iv1'ac.0"
; CHECK-NEXT:   %[[V35:.+]] = getelementptr inbounds double, double* %[[V33]], i64 %[[V34]]
; CHECK-NEXT:   %[[V36:.+]] = load double, double* %[[V35]], align 8, !invariant.group ![[G1]]
; CHECK-NEXT:   %[[V37:.+]] = fmul fast double %differeturn, %[[V36]]
; CHECK-NEXT:   %[[V38:.+]] = fadd fast double %[[V37]], %[[V37]]
; CHECK-NEXT:   call void @diffeget(double* %x, double* %"x'", i64 undef, i64 %"iv1'ac.0", double %[[V38]])
; CHECK-NEXT:   %[[V39:.+]] = icmp eq i64 %"iv1'ac.0", 0
; CHECK-NEXT:   br i1 %[[V39]], label %invertfor.cond3.preheader, label %incinvertfor.body7

; CHECK: incinvertfor.body7:
; CHECK-NEXT:   %[[V40]] = add nsw i64 %"iv1'ac.0", -1
; CHECK-NEXT:   br label %invertfor.body7

; CHECK: invertfor.cond.cleanup6:
; CHECK-NEXT:   %"iv'ac.0" = phi i64 [ %[[V28]], %incinvertfor.cond3.preheader ], [ %n, %for.cond.cleanup6 ]
; CHECK-NEXT:   br label %invertfor.body7
; CHECK-NEXT: }
