; RUN: if [ %llvmver -lt 16 ] && [ %llvmver -gt 11 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme-detect-readthrow=0 -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: if [ %llvmver -gt 11 ]; then %opt < %s %newLoadEnzyme -enzyme-preopt=false -enzyme-detect-readthrow=0 -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s; fi

; Function Attrs: nounwind uwtable
define dso_local void @compute(double* noalias nocapture %data, i64* noalias nocapture readnone %array, double* noalias nocapture %out) #0 {
entry:
  br label %for.body5.preheader

for.cond.cleanup:                                 ; preds = %for.cond.cleanup4
  store double 0.000000e+00, double* %data, align 8, !tbaa !2
  ret void

for.body5.preheader:                              ; preds = %entry, %for.cond.cleanup4
  %indvars.iv = phi i64 [ 0, %entry ], [ %indvars.iv.next, %for.cond.cleanup4 ]
  %call = tail call i64 @getSize() #2
  br label %for.body5

for.cond.cleanup4:                                ; preds = %for.body5
  %arrayidx7 = getelementptr inbounds double, double* %out, i64 %indvars.iv
  store double %add, double* %arrayidx7, align 8, !tbaa !2
  %indvars.iv.next = add nuw nsw i64 %indvars.iv, 1
  %exitcond29 = icmp eq i64 %indvars.iv.next, 10
  br i1 %exitcond29, label %for.cond.cleanup, label %for.body5.preheader

for.body5:                                        ; preds = %for.body5, %for.body5.preheader
  %j.027 = phi i64 [ %inc, %for.body5 ], [ 0, %for.body5.preheader ]
  %res.026 = phi double [ %add, %for.body5 ], [ 0.000000e+00, %for.body5.preheader ]
  %arrayidx = getelementptr inbounds double, double* %data, i64 %j.027
  %i0 = load double, double* %arrayidx, align 8, !tbaa !2
  %mul = fmul double %i0, %i0
  %add = fadd double %res.026, %mul
  %inc = add nuw i64 %j.027, 1
  %exitcond = icmp eq i64 %inc, %call
  br i1 %exitcond, label %for.cond.cleanup4, label %for.body5
}

declare dso_local i64 @getSize() local_unnamed_addr #1

; Function Attrs: nounwind
declare void @llvm.assume(i1) #2

; Function Attrs: nounwind uwtable
define dso_local void @call(double* %data, double* %d_data, i64* %array, double* %out, double* %d_out) local_unnamed_addr #0 {
entry:
  tail call void (i8*, ...) @__enzyme_autodiff(i8* bitcast (void (double*, i64*, double*)* @compute to i8*), double* %data, double* %d_data, i64* %array, double* %out, double* %d_out) #2
  ret void
}

declare dso_local void @__enzyme_autodiff(i8*, ...) local_unnamed_addr #1

attributes #0 = { nounwind uwtable "correctly-rounded-divide-sqrt-fp-math"="false" "disable-tail-calls"="false" "less-precise-fpmad"="false" "no-frame-pointer-elim"="false" "no-infs-fp-math"="false" "no-jump-tables"="false" "no-nans-fp-math"="false" "no-signed-zeros-fp-math"="false" "no-trapping-math"="false" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+fxsr,+mmx,+sse,+sse2,+x87" "unsafe-fp-math"="false" "use-soft-float"="false" }
attributes #1 = { "correctly-rounded-divide-sqrt-fp-math"="false" "disable-tail-calls"="false" "less-precise-fpmad"="false" "no-frame-pointer-elim"="false" "no-infs-fp-math"="false" "no-nans-fp-math"="false" "no-signed-zeros-fp-math"="false" "no-trapping-math"="false" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+fxsr,+mmx,+sse,+sse2,+x87" "unsafe-fp-math"="false" "use-soft-float"="false" }
attributes #2 = { nounwind }

!llvm.module.flags = !{!0}
!llvm.ident = !{!1}

!0 = !{i32 1, !"wchar_size", i32 4}
!1 = !{!"clang version 7.1.0 "}
!2 = !{!3, !3, i64 0}
!3 = !{!"double", !4, i64 0}
!4 = !{!"omnipotent char", !5, i64 0}
!5 = !{!"Simple C/C++ TBAA"}

; The first table slot owns the growing value buffer; later slots hold offsets.
; CHECK-LABEL: define internal void @diffecompute(double* noalias nocapture %data, double* nocapture %"data'", i64* noalias nocapture readnone %array, double* noalias nocapture %out, double* nocapture %"out'")
; CHECK: entry:
; CHECK-NEXT:   %malloccall = tail call noalias nonnull dereferenceable(80) dereferenceable_or_null(80) i8* @malloc(i64 80)
; CHECK-NEXT:   %call_malloccache = bitcast i8* %malloccall to i64*
; CHECK-NEXT:   %malloccall10 = tail call noalias nonnull dereferenceable(88) dereferenceable_or_null(88) i8* @malloc(i64 88)
; CHECK-NEXT:   %i0_malloccache = bitcast i8* %malloccall10 to double**
; CHECK-NEXT:   store double* null, double** %i0_malloccache, align 8
; CHECK-NEXT:   br label %for.body5.preheader

; CHECK: for.cond.cleanup:
; CHECK-NEXT:   store double 0.000000e+00, double* %data, align 8
; CHECK-NEXT:   store double 0.000000e+00, double* %"data'", align 8
; CHECK-NEXT:   br label %invertfor.cond.cleanup4

; CHECK: for.body5.preheader:
; CHECK-NEXT:   %i0_used.0 = phi i64 [ 0, %entry ], [ %[[V4:.+]], %for.cond.cleanup4 ]
; CHECK-NEXT:   %i0_capacity.0 = phi i64 [ 0, %entry ], [ %[[V11:.+]], %for.cond.cleanup4 ]
; CHECK-NEXT:   %iv = phi i64 [ %iv.next, %for.cond.cleanup4 ], [ 0, %entry ]
; CHECK-NEXT:   %iv.next = add nuw nsw i64 %iv, 1
; CHECK-NEXT:   %call = tail call i64 @getSize()
; CHECK-NEXT:   %[[V0:.+]] = getelementptr inbounds i64, i64* %call_malloccache, i64 %iv
; CHECK-NEXT:   store i64 %call, i64* %[[V0]], align 8, !invariant.group ![[G0:[0-9]+]]
; CHECK-NEXT:   %[[V1:.+]] = add i64 %iv, 1
; CHECK-NEXT:   %[[V2:.+]] = getelementptr inbounds double*, double** %i0_malloccache, i64 %[[V1]]
; CHECK-NEXT:   %[[V3:.+]] = load double*, double** %i0_malloccache, align 8
; CHECK-NEXT:   %[[V4]] = add nuw i64 %i0_used.0, %call
; CHECK-NEXT:   %[[V5:.+]] = shl i64 %i0_capacity.0, 1
; CHECK-NEXT:   %[[V6:.+]] = icmp ule i64 %i0_capacity.0, 1152921504606846975
; CHECK-NEXT:   %[[V7:.+]] = select i1 %[[V6]], i64 %[[V5]], i64 %[[V4]]
; CHECK-NEXT:   %[[V8:.+]] = icmp ugt i64 %[[V4]], %[[V7]]
; CHECK-NEXT:   %[[V9:.+]] = select i1 %[[V8]], i64 %[[V4]], i64 %[[V7]]
; CHECK-NEXT:   %[[V10:.+]] = icmp ugt i64 %[[V4]], %i0_capacity.0
; CHECK-NEXT:   %[[V11]] = select i1 %[[V10]], i64 %[[V9]], i64 %i0_capacity.0
; CHECK-NEXT:   %[[V12:.+]] = bitcast double* %[[V3]] to i8*
; CHECK-NEXT:   %[[V13:.+]] = mul nuw i64 %i0_capacity.0, 8
; CHECK-NEXT:   %[[V14:.+]] = mul nuw i64 %[[V11]], 8
; CHECK-NEXT:   %[[V15:.+]] = icmp ugt i64 %[[V14]], %[[V13]]
; CHECK-NEXT:   br i1 %[[V15]], label %grow.i, label %__enzyme_grow_ragged_cache_double.exit

; CHECK: grow.i:
; CHECK-NEXT:   %[[V16:.+]] = call noalias nonnull i8* @malloc(i64 %[[V14]])
; CHECK-NEXT:   call void @llvm.memcpy.p0i8.p0i8.i64(i8* align 1 %[[V16]], i8* align 1 %[[V12]], i64 %[[V13]], i1 false)
; CHECK-NEXT:   call void @free(i8* %[[V12]])
; CHECK-NEXT:   br label %__enzyme_grow_ragged_cache_double.exit

; CHECK: __enzyme_grow_ragged_cache_double.exit:
; CHECK-NEXT:   %[[V17:.+]] = phi i8* [ %[[V12]], %for.body5.preheader ], [ %[[V16]], %grow.i ]
; CHECK-NEXT:   %[[V18:.+]] = bitcast i8* %[[V17]] to double*
; CHECK-NEXT:   store double* %[[V18]], double** %i0_malloccache, align 8
; CHECK-NEXT:   %[[V19:.+]] = inttoptr i64 %i0_used.0 to double*
; CHECK-NEXT:   store double* %[[V19]], double** %[[V2]], align 8, !invariant.group ![[G1:[0-9]+]]
; CHECK-NEXT:   %[[V20:.+]] = add i64 %iv, 1
; CHECK-NEXT:   %[[V21:.+]] = getelementptr inbounds double*, double** %i0_malloccache, i64 %[[V20]]
; CHECK-NEXT:   %[[V22:.+]] = load double*, double** %[[V21]], align 8
; CHECK-NEXT:   %[[V23:.+]] = ptrtoint double* %[[V22]] to i64
; CHECK-NEXT:   %[[V24:.+]] = load double*, double** %i0_malloccache, align 8
; CHECK-NEXT:   %[[V25:.+]] = getelementptr inbounds double, double* %[[V24]], i64 %[[V23]]
; CHECK-NEXT:   %[[V26:.+]] = bitcast double* %[[V25]] to i8*
; CHECK-NEXT:   %[[V27:.+]] = bitcast double* %data to i8*
; CHECK-NEXT:   %[[V28:.+]] = mul nuw nsw i64 8, %call
; CHECK-NEXT:   call void @llvm.memcpy.p0i8.p0i8.i64(i8* nonnull align 8 %[[V26]], i8* nonnull align 8 %[[V27]], i64 %[[V28]], i1 false)
; CHECK-NEXT:   br label %for.body5

; CHECK: for.cond.cleanup4:
; CHECK-NEXT:   %arrayidx7 = getelementptr inbounds double, double* %out, i64 %iv
; CHECK-NEXT:   store double %add, double* %arrayidx7, align 8
; CHECK-NEXT:   %exitcond29 = icmp eq i64 %iv.next, 10
; CHECK-NEXT:   br i1 %exitcond29, label %for.cond.cleanup, label %for.body5.preheader

; CHECK: for.body5:
; CHECK-NEXT:   %iv1 = phi i64 [ %iv.next2, %for.body5 ], [ 0, %__enzyme_grow_ragged_cache_double.exit ]
; CHECK-NEXT:   %res.026 = phi double [ %add, %for.body5 ], [ 0.000000e+00, %__enzyme_grow_ragged_cache_double.exit ]
; CHECK-NEXT:   %iv.next2 = add nuw nsw i64 %iv1, 1
; CHECK-NEXT:   %arrayidx = getelementptr inbounds double, double* %data, i64 %iv1
; CHECK-NEXT:   %i0 = load double, double* %arrayidx, align 8
; CHECK-NEXT:   %mul = fmul double %i0, %i0
; CHECK-NEXT:   %add = fadd double %res.026, %mul
; CHECK-NEXT:   %exitcond = icmp eq i64 %iv.next2, %call
; CHECK-NEXT:   br i1 %exitcond, label %for.cond.cleanup4, label %for.body5

; CHECK: invertentry:
; CHECK-NEXT:   tail call void @free(i8* nonnull %malloccall)
; CHECK-NEXT:   %[[V29:.+]] = load double*, double** %i0_malloccache, align 8
; CHECK-NEXT:   %[[V30:.+]] = bitcast double* %[[V29]] to i8*
; CHECK-NEXT:   tail call void @free(i8* %[[V30]])
; CHECK-NEXT:   tail call void @free(i8* nonnull %malloccall10)
; CHECK-NEXT:   ret void

; CHECK: invertfor.body5.preheader:
; CHECK-NEXT:   %[[V31:.+]] = icmp eq i64 %"iv'ac.0", 0
; CHECK-NEXT:   br i1 %[[V31]], label %invertentry, label %incinvertfor.body5.preheader

; CHECK: incinvertfor.body5.preheader:
; CHECK-NEXT:   %[[V32:.+]] = add nsw i64 %"iv'ac.0", -1
; CHECK-NEXT:   br label %invertfor.cond.cleanup4

; CHECK: invertfor.cond.cleanup4:
; CHECK-NEXT:   %"add'de.0" = phi double [ 0.000000e+00, %for.cond.cleanup ], [ %[[V51:.+]], %incinvertfor.body5.preheader ]
; CHECK-NEXT:   %"iv'ac.0" = phi i64 [ 9, %for.cond.cleanup ], [ %[[V32]], %incinvertfor.body5.preheader ]
; CHECK-NEXT:   %"arrayidx7'ipg_unwrap" = getelementptr inbounds double, double* %"out'", i64 %"iv'ac.0"
; CHECK-NEXT:   %[[V33:.+]] = load double, double* %"arrayidx7'ipg_unwrap", align 8
; CHECK-NEXT:   store double 0.000000e+00, double* %"arrayidx7'ipg_unwrap", align 8
; CHECK-NEXT:   %[[V34:.+]] = fadd fast double %"add'de.0", %[[V33]]
; CHECK-NEXT:   %[[V35:.+]] = getelementptr inbounds i64, i64* %call_malloccache, i64 %"iv'ac.0"
; CHECK-NEXT:   %[[V36:.+]] = load i64, i64* %[[V35]], align 8, !invariant.group ![[G0]]
; CHECK-NEXT:   %_unwrap = add i64 %[[V36]], -1
; CHECK-NEXT:   br label %invertfor.body5

; CHECK: invertfor.body5:
; CHECK-NEXT:   %"add'de.1" = phi double [ %[[V34]], %invertfor.cond.cleanup4 ], [ %[[V51]], %incinvertfor.body5 ]
; CHECK-NEXT:   %"iv1'ac.0" = phi i64 [ %_unwrap, %invertfor.cond.cleanup4 ], [ %[[V52:.+]], %incinvertfor.body5 ]
; CHECK-NEXT:   %[[V37:.+]] = add i64 %"iv'ac.0", 1
; CHECK-NEXT:   %[[V38:.+]] = getelementptr inbounds double*, double** %i0_malloccache, i64 %[[V37]]
; CHECK-NEXT:   %[[V39:.+]] = load double*, double** %[[V38]], align 8
; CHECK-NEXT:   %[[V40:.+]] = ptrtoint double* %[[V39]] to i64
; CHECK-NEXT:   %[[V41:.+]] = load double*, double** %i0_malloccache, align 8
; CHECK-NEXT:   %[[V42:.+]] = getelementptr inbounds double, double* %[[V41]], i64 %[[V40]]
; CHECK-NEXT:   %[[V43:.+]] = getelementptr inbounds double, double* %[[V42]], i64 %"iv1'ac.0"
; CHECK-NEXT:   %[[V44:.+]] = load double, double* %[[V43]], align 8, !invariant.group ![[G2:[0-9]+]]
; CHECK-NEXT:   %[[V45:.+]] = fmul fast double %"add'de.1", %[[V44]]
; CHECK-NEXT:   %[[V46:.+]] = fmul fast double %"add'de.1", %[[V44]]
; CHECK-NEXT:   %[[V47:.+]] = fadd fast double %[[V45]], %[[V46]]
; CHECK-NEXT:   %"arrayidx'ipg_unwrap" = getelementptr inbounds double, double* %"data'", i64 %"iv1'ac.0"
; CHECK-NEXT:   %[[V48:.+]] = load double, double* %"arrayidx'ipg_unwrap", align 8
; CHECK-NEXT:   %[[V49:.+]] = fadd fast double %[[V48]], %[[V47]]
; CHECK-NEXT:   store double %[[V49]], double* %"arrayidx'ipg_unwrap", align 8
; CHECK-NEXT:   %[[V50:.+]] = icmp eq i64 %"iv1'ac.0", 0
; CHECK-NEXT:   %[[V51]] = select fast i1 %[[V50]], double 0.000000e+00, double %"add'de.1"
; CHECK-NEXT:   br i1 %[[V50]], label %invertfor.body5.preheader, label %incinvertfor.body5

; CHECK: incinvertfor.body5:
; CHECK-NEXT:   %[[V52]] = add nsw i64 %"iv1'ac.0", -1
; CHECK-NEXT:   br label %invertfor.body5
; CHECK-NEXT: }
