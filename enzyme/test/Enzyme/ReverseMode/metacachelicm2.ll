; RUN: if [ %llvmver -lt 16 ] && [ %llvmver -gt 11 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme-detect-readthrow=0 -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: if [ %llvmver -gt 11 ]; then %opt < %s %newLoadEnzyme -enzyme-preopt=false -enzyme-detect-readthrow=0 -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s; fi

; Function Attrs: nounwind uwtable
define dso_local void @compute(double* noalias nocapture %data, i64* noalias nocapture readonly %array, double* noalias nocapture %out) #0 {
entry:
  br label %for.body5.preheader

for.cond.cleanup:                                 ; preds = %for.cond.cleanup4
  store double 0.000000e+00, double* %data, align 8, !tbaa !2
  ret void

for.body5.preheader:                              ; preds = %entry, %for.cond.cleanup4
  %indvars.iv = phi i64 [ 0, %entry ], [ %indvars.iv.next, %for.cond.cleanup4 ]
  %arrayidx = getelementptr inbounds i64, i64* %array, i64 %indvars.iv
  %len = load i64, i64* %arrayidx, align 8, !tbaa !6
  br label %for.body5

for.cond.cleanup4:                                ; preds = %for.body5
  %arrayidx9 = getelementptr inbounds double, double* %out, i64 %indvars.iv
  store double %add, double* %arrayidx9, align 8, !tbaa !2
  %indvars.iv.next = add nuw nsw i64 %indvars.iv, 1
  %exitcond32 = icmp eq i64 %indvars.iv.next, 10
  br i1 %exitcond32, label %for.cond.cleanup, label %for.body5.preheader

for.body5:                                        ; preds = %for.body5, %for.body5.preheader
  %j = phi i64 [ %inc, %for.body5 ], [ 0, %for.body5.preheader ]
  %res.029 = phi double [ %add, %for.body5 ], [ 0.000000e+00, %for.body5.preheader ]
  %arrayidx6 = getelementptr inbounds double, double* %data, i64 %j
  %ld = load double, double* %arrayidx6, align 8, !tbaa !2
  %mul = fmul double %ld, %ld
  %add = fadd double %res.029, %mul
  %inc = add nuw i64 %j, 1
  %exitcond = icmp eq i64 %inc, %len
  br i1 %exitcond, label %for.cond.cleanup4, label %for.body5
}

; Function Attrs: nounwind
declare void @llvm.assume(i1) #1

; Function Attrs: nounwind uwtable
define dso_local void @call(double* %data, double* %d_data, i64* %array, double* %out, double* %d_out) local_unnamed_addr #0 {
entry:
  tail call void (i8*, ...) @__enzyme_autodiff(i8* bitcast (void (double*, i64*, double*)* @compute to i8*), double* %data, double* %d_data, i64* %array, double* %out, double* %d_out) #1
  ret void
}

declare dso_local void @__enzyme_autodiff(i8*, ...) local_unnamed_addr #2

attributes #0 = { nounwind uwtable "correctly-rounded-divide-sqrt-fp-math"="false" "disable-tail-calls"="false" "less-precise-fpmad"="false" "no-frame-pointer-elim"="false" "no-infs-fp-math"="false" "no-jump-tables"="false" "no-nans-fp-math"="false" "no-signed-zeros-fp-math"="false" "no-trapping-math"="false" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+fxsr,+mmx,+sse,+sse2,+x87" "unsafe-fp-math"="false" "use-soft-float"="false" }
attributes #1 = { nounwind }
attributes #2 = { "correctly-rounded-divide-sqrt-fp-math"="false" "disable-tail-calls"="false" "less-precise-fpmad"="false" "no-frame-pointer-elim"="false" "no-infs-fp-math"="false" "no-nans-fp-math"="false" "no-signed-zeros-fp-math"="false" "no-trapping-math"="false" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+fxsr,+mmx,+sse,+sse2,+x87" "unsafe-fp-math"="false" "use-soft-float"="false" }

!llvm.module.flags = !{!0}
!llvm.ident = !{!1}

!0 = !{i32 1, !"wchar_size", i32 4}
!1 = !{!"clang version 7.1.0 "}
!2 = !{!3, !3, i64 0}
!3 = !{!"double", !4, i64 0}
!4 = !{!"omnipotent char", !5, i64 0}
!5 = !{!"Simple C/C++ TBAA"}
!6 = !{!7, !7, i64 0}
!7 = !{!"long", !4, i64 0}

; The first table slot owns the growing value buffer; later slots hold offsets.
; CHECK-LABEL: define internal void @diffecompute(double* noalias nocapture %data, double* nocapture %"data'", i64* noalias nocapture readonly %array, double* noalias nocapture %out, double* nocapture %"out'")
; CHECK: entry:
; CHECK-NEXT:   %malloccall = tail call noalias nonnull dereferenceable(88) dereferenceable_or_null(88) i8* @malloc(i64 88)
; CHECK-NEXT:   %ld_malloccache = bitcast i8* %malloccall to double**
; CHECK-NEXT:   store double* null, double** %ld_malloccache, align 8
; CHECK-NEXT:   br label %for.body5.preheader

; CHECK: for.cond.cleanup:
; CHECK-NEXT:   store double 0.000000e+00, double* %data, align 8
; CHECK-NEXT:   store double 0.000000e+00, double* %"data'", align 8
; CHECK-NEXT:   br label %invertfor.cond.cleanup4

; CHECK: for.body5.preheader:
; CHECK-NEXT:   %ld_capacity.0 = phi i64 [ 0, %entry ], [ %[[V10:.+]], %for.cond.cleanup4 ]
; CHECK-NEXT:   %ld_used.0 = phi i64 [ 0, %entry ], [ %[[V3:.+]], %for.cond.cleanup4 ]
; CHECK-NEXT:   %iv = phi i64 [ %iv.next, %for.cond.cleanup4 ], [ 0, %entry ]
; CHECK-NEXT:   %iv.next = add nuw nsw i64 %iv, 1
; CHECK-NEXT:   %arrayidx = getelementptr inbounds i64, i64* %array, i64 %iv
; CHECK-NEXT:   %len = load i64, i64* %arrayidx, align 8{{.*}}, !invariant.group ![[G0:[0-9]+]]
; CHECK-NEXT:   %[[V0:.+]] = add i64 %iv, 1
; CHECK-NEXT:   %[[V1:.+]] = getelementptr inbounds double*, double** %ld_malloccache, i64 %[[V0]]
; CHECK-NEXT:   %[[V2:.+]] = load double*, double** %ld_malloccache, align 8
; CHECK-NEXT:   %[[V3]] = add nuw i64 %ld_used.0, %len
; CHECK-NEXT:   %[[V4:.+]] = shl i64 %ld_capacity.0, 1
; CHECK-NEXT:   %[[V5:.+]] = icmp ule i64 %ld_capacity.0, 1152921504606846975
; CHECK-NEXT:   %[[V6:.+]] = select i1 %[[V5]], i64 %[[V4]], i64 %[[V3]]
; CHECK-NEXT:   %[[V7:.+]] = icmp ugt i64 %[[V3]], %[[V6]]
; CHECK-NEXT:   %[[V8:.+]] = select i1 %[[V7]], i64 %[[V3]], i64 %[[V6]]
; CHECK-NEXT:   %[[V9:.+]] = icmp ugt i64 %[[V3]], %ld_capacity.0
; CHECK-NEXT:   %[[V10]] = select i1 %[[V9]], i64 %[[V8]], i64 %ld_capacity.0
; CHECK-NEXT:   %[[V11:.+]] = bitcast double* %[[V2]] to i8*
; CHECK-NEXT:   %[[V12:.+]] = mul nuw i64 %ld_capacity.0, 8
; CHECK-NEXT:   %[[V13:.+]] = mul nuw i64 %[[V10]], 8
; CHECK-NEXT:   %[[V14:.+]] = icmp ugt i64 %[[V13]], %[[V12]]
; CHECK-NEXT:   br i1 %[[V14]], label %grow.i, label %__enzyme_grow_ragged_cache_double.exit

; CHECK: grow.i:
; CHECK-NEXT:   %[[V15:.+]] = call noalias nonnull i8* @malloc(i64 %[[V13]])
; CHECK-NEXT:   call void @llvm.memcpy.p0i8.p0i8.i64(i8* align 1 %[[V15]], i8* align 1 %[[V11]], i64 %[[V12]], i1 false)
; CHECK-NEXT:   call void @free(i8* %[[V11]])
; CHECK-NEXT:   br label %__enzyme_grow_ragged_cache_double.exit

; CHECK: __enzyme_grow_ragged_cache_double.exit:
; CHECK-NEXT:   %[[V16:.+]] = phi i8* [ %[[V11]], %for.body5.preheader ], [ %[[V15]], %grow.i ]
; CHECK-NEXT:   %[[V17:.+]] = bitcast i8* %[[V16]] to double*
; CHECK-NEXT:   store double* %[[V17]], double** %ld_malloccache, align 8
; CHECK-NEXT:   %[[V18:.+]] = inttoptr i64 %ld_used.0 to double*
; CHECK-NEXT:   store double* %[[V18]], double** %[[V1]], align 8{{.*}}, !invariant.group ![[G1:[0-9]+]]
; CHECK-NEXT:   %[[V19:.+]] = add i64 %iv, 1
; CHECK-NEXT:   %[[V20:.+]] = getelementptr inbounds double*, double** %ld_malloccache, i64 %[[V19]]
; CHECK-NEXT:   %[[V21:.+]] = load double*, double** %[[V20]], align 8
; CHECK-NEXT:   %[[V22:.+]] = ptrtoint double* %[[V21]] to i64
; CHECK-NEXT:   %[[V23:.+]] = load double*, double** %ld_malloccache, align 8
; CHECK-NEXT:   %[[V24:.+]] = getelementptr inbounds double, double* %[[V23]], i64 %[[V22]]
; CHECK-NEXT:   %[[V25:.+]] = bitcast double* %[[V24]] to i8*
; CHECK-NEXT:   %[[V26:.+]] = bitcast double* %data to i8*
; CHECK-NEXT:   %[[V27:.+]] = mul nuw nsw i64 8, %len
; CHECK-NEXT:   call void @llvm.memcpy.p0i8.p0i8.i64(i8* nonnull align 8 %[[V25]], i8* nonnull align 8 %[[V26]], i64 %[[V27]], i1 false)
; CHECK-NEXT:   br label %for.body5

; CHECK: for.cond.cleanup4:
; CHECK-NEXT:   %arrayidx9 = getelementptr inbounds double, double* %out, i64 %iv
; CHECK-NEXT:   store double %add, double* %arrayidx9, align 8
; CHECK-NEXT:   %exitcond32 = icmp eq i64 %iv.next, 10
; CHECK-NEXT:   br i1 %exitcond32, label %for.cond.cleanup, label %for.body5.preheader

; CHECK: for.body5:
; CHECK-NEXT:   %iv1 = phi i64 [ %iv.next2, %for.body5 ], [ 0, %__enzyme_grow_ragged_cache_double.exit ]
; CHECK-NEXT:   %res.029 = phi double [ %add, %for.body5 ], [ 0.000000e+00, %__enzyme_grow_ragged_cache_double.exit ]
; CHECK-NEXT:   %iv.next2 = add nuw nsw i64 %iv1, 1
; CHECK-NEXT:   %arrayidx6 = getelementptr inbounds double, double* %data, i64 %iv1
; CHECK-NEXT:   %ld = load double, double* %arrayidx6, align 8
; CHECK-NEXT:   %mul = fmul double %ld, %ld
; CHECK-NEXT:   %add = fadd double %res.029, %mul
; CHECK-NEXT:   %exitcond = icmp eq i64 %iv.next2, %len
; CHECK-NEXT:   br i1 %exitcond, label %for.cond.cleanup4, label %for.body5

; CHECK: invertentry:
; CHECK-NEXT:   %[[V28:.+]] = load double*, double** %ld_malloccache, align 8
; CHECK-NEXT:   %[[V29:.+]] = bitcast double* %[[V28]] to i8*
; CHECK-NEXT:   tail call void @free(i8* %[[V29]])
; CHECK-NEXT:   tail call void @free(i8* nonnull %malloccall)
; CHECK-NEXT:   ret void

; CHECK: invertfor.body5.preheader:
; CHECK-NEXT:   %[[V30:.+]] = icmp eq i64 %"iv'ac.0", 0
; CHECK-NEXT:   br i1 %[[V30]], label %invertentry, label %incinvertfor.body5.preheader

; CHECK: incinvertfor.body5.preheader:
; CHECK-NEXT:   %[[V31:.+]] = add nsw i64 %"iv'ac.0", -1
; CHECK-NEXT:   br label %invertfor.cond.cleanup4

; CHECK: invertfor.cond.cleanup4:
; CHECK-NEXT:   %"add'de.0" = phi double [ 0.000000e+00, %for.cond.cleanup ], [ %[[V48:.+]], %incinvertfor.body5.preheader ]
; CHECK-NEXT:   %"iv'ac.0" = phi i64 [ 9, %for.cond.cleanup ], [ %[[V31]], %incinvertfor.body5.preheader ]
; CHECK-NEXT:   %"arrayidx9'ipg_unwrap" = getelementptr inbounds double, double* %"out'", i64 %"iv'ac.0"
; CHECK-NEXT:   %[[V32:.+]] = load double, double* %"arrayidx9'ipg_unwrap", align 8
; CHECK-NEXT:   store double 0.000000e+00, double* %"arrayidx9'ipg_unwrap", align 8
; CHECK-NEXT:   %[[V33:.+]] = fadd fast double %"add'de.0", %[[V32]]
; CHECK-NEXT:   %arrayidx_unwrap = getelementptr inbounds i64, i64* %array, i64 %"iv'ac.0"
; CHECK-NEXT:   %len_unwrap = load i64, i64* %arrayidx_unwrap, align 8{{.*}}, !invariant.group ![[G0]]
; CHECK-NEXT:   %_unwrap = add i64 %len_unwrap, -1
; CHECK-NEXT:   br label %invertfor.body5

; CHECK: invertfor.body5:
; CHECK-NEXT:   %"add'de.1" = phi double [ %[[V33]], %invertfor.cond.cleanup4 ], [ %[[V48]], %incinvertfor.body5 ]
; CHECK-NEXT:   %"iv1'ac.0" = phi i64 [ %_unwrap, %invertfor.cond.cleanup4 ], [ %[[V49:.+]], %incinvertfor.body5 ]
; CHECK-NEXT:   %[[V34:.+]] = add i64 %"iv'ac.0", 1
; CHECK-NEXT:   %[[V35:.+]] = getelementptr inbounds double*, double** %ld_malloccache, i64 %[[V34]]
; CHECK-NEXT:   %[[V36:.+]] = load double*, double** %[[V35]], align 8
; CHECK-NEXT:   %[[V37:.+]] = ptrtoint double* %[[V36]] to i64
; CHECK-NEXT:   %[[V38:.+]] = load double*, double** %ld_malloccache, align 8
; CHECK-NEXT:   %[[V39:.+]] = getelementptr inbounds double, double* %[[V38]], i64 %[[V37]]
; CHECK-NEXT:   %[[V40:.+]] = getelementptr inbounds double, double* %[[V39]], i64 %"iv1'ac.0"
; CHECK-NEXT:   %[[V41:.+]] = load double, double* %[[V40]], align 8{{.*}}, !invariant.group ![[G2:[0-9]+]]
; CHECK-NEXT:   %[[V42:.+]] = fmul fast double %"add'de.1", %[[V41]]
; CHECK-NEXT:   %[[V43:.+]] = fmul fast double %"add'de.1", %[[V41]]
; CHECK-NEXT:   %[[V44:.+]] = fadd fast double %[[V42]], %[[V43]]
; CHECK-NEXT:   %"arrayidx6'ipg_unwrap" = getelementptr inbounds double, double* %"data'", i64 %"iv1'ac.0"
; CHECK-NEXT:   %[[V45:.+]] = load double, double* %"arrayidx6'ipg_unwrap", align 8
; CHECK-NEXT:   %[[V46:.+]] = fadd fast double %[[V45]], %[[V44]]
; CHECK-NEXT:   store double %[[V46]], double* %"arrayidx6'ipg_unwrap", align 8
; CHECK-NEXT:   %[[V47:.+]] = icmp eq i64 %"iv1'ac.0", 0
; CHECK-NEXT:   %[[V48]] = select fast i1 %[[V47]], double 0.000000e+00, double %"add'de.1"
; CHECK-NEXT:   br i1 %[[V47]], label %invertfor.body5.preheader, label %incinvertfor.body5

; CHECK: incinvertfor.body5:
; CHECK-NEXT:   %[[V49]] = add nsw i64 %"iv1'ac.0", -1
; CHECK-NEXT:   br label %invertfor.body5
; CHECK-NEXT: }
