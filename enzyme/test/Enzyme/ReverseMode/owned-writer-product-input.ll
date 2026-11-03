; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; A later call that fills the storage of the array it received, rather than
; of the one it allocates, may overwrite what the call read.

declare void @__enzyme_autodiff(...)
declare noalias ptr @enzyme_allocator(i64) #0
declare void @consume(ptr) readonly nofree "enzyme_inactive"
declare ptr @julia.pointer_from_objref(ptr) readnone nofree nounwind
; Writes only through its second pointer argument, as attributeBLAS states for
; a BLAS routine's output.
declare void @blas_fill(ptr nocapture readonly, ptr nocapture) argmemonly nofree nounwind "enzyme_inactive"

; Fills the storage owned by its first argument from the second's, through a
; foreign call, reading the owning pointer through the object's address and
; keeping both objects alive with a jl_roots bundle, as Julia's BLAS wrappers
; do.
define internal void @gemm(ptr %out, ptr %in) #1 {
entry:
  %obj = call ptr @julia.pointer_from_objref(ptr %out)
  %dst = load ptr, ptr %obj
  %src = load ptr, ptr %in
  call void @blas_fill(ptr %src, ptr %dst) [ "jl_roots"(ptr %out, ptr %in) ]
  ret void
}

; Forwards to gemm, as gemm_wrapper! does.
define internal void @wrapper(ptr %out, ptr %in) #1 {
entry:
  call void @gemm(ptr %out, ptr %in)
  ret void
}

; Returns a new array computed from its argument, as Julia's matrix product.
define internal noalias ptr @product(ptr %arr) #1 {
entry:
  %new = call noalias ptr @enzyme_allocator(i64 8)
  call void @wrapper(ptr %arr, ptr %new)
  ret ptr %new
}

define internal double @sqdist(ptr %arr, double %m) {
entry:
  %data = load ptr, ptr %arr
  %np = getelementptr inbounds i8, ptr %arr, i64 8
  %n = load i64, ptr %np
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %inc, %loop ]
  %acc = phi double [ 0.0, %entry ], [ %acc.next, %loop ]
  %p = getelementptr inbounds double, ptr %data, i64 %i
  %y = load double, ptr %p
  %d = fsub double %y, %m
  %sq = fmul double %d, %d
  %acc.next = fadd double %acc, %sq
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %acc.next
}

define double @f({ ptr, ptr } %agg, double %m) {
entry:
  %arr = extractvalue { ptr, ptr } %agg, 0
  %r = call double @sqdist(ptr %arr, double %m)
  %new = call ptr @product(ptr %arr)
  call void @consume(ptr %new)
  ret double %r
}

define void @test({ ptr, ptr } %agg, double %m) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", { ptr, ptr } %agg, double %m)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_fresh_pointer"="0" "enzyme_inactive" }
attributes #1 = { nofree "enzyme_inactive" }

; CHECK: define internal {{.*}} @augmented_sqdist(
; CHECK: call {{.*}} @malloc(
