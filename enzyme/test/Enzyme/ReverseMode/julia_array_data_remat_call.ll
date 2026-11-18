; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-julia-addr-load -passes="enzyme" -S | FileCheck %s; fi

; The call version of julia_array_data_remat.ll, reduced from Enzyme.jl on
; Julia 1.10 (an RKPPL MvNormal slice prior):
;   fill!(t, x) = (for i in eachindex(x); t[i] = x[i] - 1.0; end; t)  # not inlined
;   mid(x, w) = (t = fill!(Vector{Float64}(undef, length(x)), x);
;                sum(t[i] * t[i] / w[i] for i in eachindex(t)))
; called from a function that uses its result again, so that mid is
; differentiated in split mode, and the reverse pass needs t[i].
;
; The callee only reads the array header, so the header operand is readonly,
; but it loads the data pointer from the header and writes the elements through
; it. That write cannot be replayed, so the allocation must not be
; rematerialized in the reverse pass: a recreated t would hold no elements.
;
; julia_mid_copy is the control: it fills its array itself (t[i] = i - 1, which
; the reverse pass can recompute), then passes it to a callee that also only
; reads its array header operand and writes the storage of its other argument.
; That callee does not write the array, so the allocation is still
; rematerialized with its fill loop, as before this check.
source_filename = "start"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128-ni:10:11:12:13"
target triple = "x86_64-linux-gnu"

; Function Attrs: mustprogress nofree nounwind willreturn
declare noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10)) #0

declare double @__enzyme_autodiff(...)

define double @dtop_fill(ptr addrspace(10) %x, ptr addrspace(10) %dx, ptr addrspace(10) %w, ptr addrspace(10) %dw) {
  %r = call double (...) @__enzyme_autodiff(ptr @julia_top_fill, metadata !"enzyme_dup", ptr addrspace(10) %x, ptr addrspace(10) %dx, metadata !"enzyme_dup", ptr addrspace(10) %w, ptr addrspace(10) %dw)
  ret double %r
}

define double @dtop_copy(ptr addrspace(10) %x, ptr addrspace(10) %dx, ptr addrspace(10) %w, ptr addrspace(10) %dw, ptr addrspace(10) %y, ptr addrspace(10) %dy) {
  %r = call double (...) @__enzyme_autodiff(ptr @julia_top_copy, metadata !"enzyme_dup", ptr addrspace(10) %x, ptr addrspace(10) %dx, metadata !"enzyme_dup", ptr addrspace(10) %w, ptr addrspace(10) %dw, metadata !"enzyme_dup", ptr addrspace(10) %y, ptr addrspace(10) %dy)
  ret double %r
}

define double @julia_top_fill(ptr addrspace(10) %x, ptr addrspace(10) %w) {
  %r = call fastcc double @julia_mid_fill(ptr addrspace(10) %x, ptr addrspace(10) %w)
  %r2 = fmul double %r, %r
  ret double %r2
}

define double @julia_top_copy(ptr addrspace(10) %x, ptr addrspace(10) %w, ptr addrspace(10) %y) {
  %r = call fastcc double @julia_mid_copy(ptr addrspace(10) %x, ptr addrspace(10) %w, ptr addrspace(10) %y)
  %r2 = fmul double %r, %r
  ret double %r2
}

; t[i] = x[i] - 1.0, through the data pointers loaded from both headers.
; Function Attrs: noinline
define internal fastcc void @julia_fill(ptr addrspace(10) nocapture noundef nonnull readonly align 16 dereferenceable(40) "enzyme_type"="{[-1]:Pointer, [-1,0]:Pointer, [-1,0,-1]:Float@double, [-1,8]:Integer, [-1,9]:Integer, [-1,10]:Integer, [-1,11]:Integer, [-1,12]:Integer, [-1,13]:Integer, [-1,14]:Integer, [-1,15]:Integer}" %t, ptr addrspace(10) nocapture noundef nonnull readonly align 16 dereferenceable(40) "enzyme_type"="{[-1]:Pointer, [-1,0]:Pointer, [-1,0,-1]:Float@double, [-1,8]:Integer, [-1,9]:Integer, [-1,10]:Integer, [-1,11]:Integer, [-1,12]:Integer, [-1,13]:Integer, [-1,14]:Integer, [-1,15]:Integer}" %x) unnamed_addr #1 {
top:
  %xa = addrspacecast ptr addrspace(10) %x to ptr addrspace(11)
  %len_ptr = getelementptr inbounds { ptr addrspace(13), i64, i16, i16, i32 }, ptr addrspace(11) %xa, i64 0, i32 1
  %len = load i64, ptr addrspace(11) %len_ptr, align 8, !tbaa !0, !enzyme_inactive !5, !enzyme_type !6
  %empty = icmp eq i64 %len, 0
  br i1 %empty, label %done, label %pre

pre:
  %xd = load ptr addrspace(13), ptr addrspace(11) %xa, align 16, !tbaa !8, !enzyme_type !10
  %ta = addrspacecast ptr addrspace(10) %t to ptr addrspace(11)
  %td = load ptr addrspace(13), ptr addrspace(11) %ta, align 8, !tbaa !8, !enzyme_type !10
  br label %loop

loop:
  %i = phi i64 [ 0, %pre ], [ %i.next, %loop ]
  %xp = getelementptr inbounds double, ptr addrspace(13) %xd, i64 %i
  %xv = load double, ptr addrspace(13) %xp, align 8, !tbaa !13, !enzyme_type !16
  %tv = fadd double %xv, -1.000000e+00
  %tp = getelementptr inbounds double, ptr addrspace(13) %td, i64 %i
  store double %tv, ptr addrspace(13) %tp, align 8, !tbaa !13
  %i.next = add nuw nsw i64 %i, 1
  %end = icmp eq i64 %i.next, %len
  br i1 %end, label %done, label %loop

done:
  ret void
}

; y[i] = t[i], through the data pointers loaded from both headers: writes the
; storage of its second argument only.
; Function Attrs: noinline
define internal fastcc void @julia_copyout(ptr addrspace(10) nocapture noundef nonnull readonly align 16 dereferenceable(40) "enzyme_type"="{[-1]:Pointer, [-1,0]:Pointer, [-1,0,-1]:Float@double, [-1,8]:Integer, [-1,9]:Integer, [-1,10]:Integer, [-1,11]:Integer, [-1,12]:Integer, [-1,13]:Integer, [-1,14]:Integer, [-1,15]:Integer}" %t, ptr addrspace(10) nocapture noundef nonnull readonly align 16 dereferenceable(40) "enzyme_type"="{[-1]:Pointer, [-1,0]:Pointer, [-1,0,-1]:Float@double, [-1,8]:Integer, [-1,9]:Integer, [-1,10]:Integer, [-1,11]:Integer, [-1,12]:Integer, [-1,13]:Integer, [-1,14]:Integer, [-1,15]:Integer}" %y) unnamed_addr #1 {
top:
  %ya = addrspacecast ptr addrspace(10) %y to ptr addrspace(11)
  %len_ptr = getelementptr inbounds { ptr addrspace(13), i64, i16, i16, i32 }, ptr addrspace(11) %ya, i64 0, i32 1
  %len = load i64, ptr addrspace(11) %len_ptr, align 8, !tbaa !0, !enzyme_inactive !5, !enzyme_type !6
  %empty = icmp eq i64 %len, 0
  br i1 %empty, label %done, label %pre

pre:
  %yd = load ptr addrspace(13), ptr addrspace(11) %ya, align 16, !tbaa !8, !enzyme_type !10
  %ta = addrspacecast ptr addrspace(10) %t to ptr addrspace(11)
  %td = load ptr addrspace(13), ptr addrspace(11) %ta, align 8, !tbaa !8, !enzyme_type !10
  br label %loop

loop:
  %i = phi i64 [ 0, %pre ], [ %i.next, %loop ]
  %tp = getelementptr inbounds double, ptr addrspace(13) %td, i64 %i
  %tv = load double, ptr addrspace(13) %tp, align 8, !tbaa !13, !enzyme_type !16
  %yp = getelementptr inbounds double, ptr addrspace(13) %yd, i64 %i
  store double %tv, ptr addrspace(13) %yp, align 8, !tbaa !13
  %i.next = add nuw nsw i64 %i, 1
  %end = icmp eq i64 %i.next, %len
  br i1 %end, label %done, label %loop

done:
  ret void
}

; sum(t[i] * t[i] / w[i] for i in eachindex(t)), shared by both mids.
; Function Attrs: noinline
define internal fastcc double @julia_mid_fill(ptr addrspace(10) nocapture nofree noundef nonnull readonly align 16 dereferenceable(40) "enzyme_type"="{[-1]:Pointer, [-1,0]:Pointer, [-1,0,-1]:Float@double, [-1,8]:Integer, [-1,9]:Integer, [-1,10]:Integer, [-1,11]:Integer, [-1,12]:Integer, [-1,13]:Integer, [-1,14]:Integer, [-1,15]:Integer}" %x, ptr addrspace(10) nocapture nofree noundef nonnull readonly align 16 dereferenceable(40) "enzyme_type"="{[-1]:Pointer, [-1,0]:Pointer, [-1,0,-1]:Float@double, [-1,8]:Integer, [-1,9]:Integer, [-1,10]:Integer, [-1,11]:Integer, [-1,12]:Integer, [-1,13]:Integer, [-1,14]:Integer, [-1,15]:Integer}" %w) unnamed_addr #1 {
top:
  %v6 = call noalias nonnull "enzyme_type"="{[-1]:Pointer, [-1,0]:Pointer, [-1,0,-1]:Float@double, [-1,8]:Integer, [-1,9]:Integer, [-1,10]:Integer, [-1,11]:Integer, [-1,12]:Integer, [-1,13]:Integer, [-1,14]:Integer, [-1,15]:Integer}" ptr addrspace(10) @julia.gc_alloc_obj(ptr null, i64 40, ptr addrspace(10) null)
  call fastcc void @julia_fill(ptr addrspace(10) nocapture noundef nonnull readonly align 16 dereferenceable(40) %v6, ptr addrspace(10) nocapture noundef nonnull readonly align 16 dereferenceable(40) %x)
  %r = call fastcc double @julia_sum_ratio(ptr addrspace(10) %v6, ptr addrspace(10) %w)
  ret double %r
}

; Function Attrs: noinline
define internal fastcc double @julia_mid_copy(ptr addrspace(10) nocapture nofree noundef nonnull readonly align 16 dereferenceable(40) "enzyme_type"="{[-1]:Pointer, [-1,0]:Pointer, [-1,0,-1]:Float@double, [-1,8]:Integer, [-1,9]:Integer, [-1,10]:Integer, [-1,11]:Integer, [-1,12]:Integer, [-1,13]:Integer, [-1,14]:Integer, [-1,15]:Integer}" %x, ptr addrspace(10) nocapture nofree noundef nonnull readonly align 16 dereferenceable(40) "enzyme_type"="{[-1]:Pointer, [-1,0]:Pointer, [-1,0,-1]:Float@double, [-1,8]:Integer, [-1,9]:Integer, [-1,10]:Integer, [-1,11]:Integer, [-1,12]:Integer, [-1,13]:Integer, [-1,14]:Integer, [-1,15]:Integer}" %w, ptr addrspace(10) nocapture noundef nonnull readonly align 16 dereferenceable(40) "enzyme_type"="{[-1]:Pointer, [-1,0]:Pointer, [-1,0,-1]:Float@double, [-1,8]:Integer, [-1,9]:Integer, [-1,10]:Integer, [-1,11]:Integer, [-1,12]:Integer, [-1,13]:Integer, [-1,14]:Integer, [-1,15]:Integer}" %y) unnamed_addr #1 {
top:
  %xa = addrspacecast ptr addrspace(10) %x to ptr addrspace(11)
  %len_ptr = getelementptr inbounds { ptr addrspace(13), i64, i16, i16, i32 }, ptr addrspace(11) %xa, i64 0, i32 1
  %len = load i64, ptr addrspace(11) %len_ptr, align 8, !tbaa !0, !enzyme_inactive !5, !enzyme_type !6
  %v6 = call noalias nonnull "enzyme_type"="{[-1]:Pointer, [-1,0]:Pointer, [-1,0,-1]:Float@double, [-1,8]:Integer, [-1,9]:Integer, [-1,10]:Integer, [-1,11]:Integer, [-1,12]:Integer, [-1,13]:Integer, [-1,14]:Integer, [-1,15]:Integer}" ptr addrspace(10) @julia.gc_alloc_obj(ptr null, i64 40, ptr addrspace(10) null)
  %empty = icmp eq i64 %len, 0
  br i1 %empty, label %filled, label %pre

pre:
  %ta = addrspacecast ptr addrspace(10) %v6 to ptr addrspace(11)
  %td = load ptr addrspace(13), ptr addrspace(11) %ta, align 8, !tbaa !8, !enzyme_type !10
  br label %loop

loop:
  %i = phi i64 [ 0, %pre ], [ %i.next, %loop ]
  %tv = sitofp i64 %i to double
  %tp = getelementptr inbounds double, ptr addrspace(13) %td, i64 %i
  store double %tv, ptr addrspace(13) %tp, align 8, !tbaa !13
  %i.next = add nuw nsw i64 %i, 1
  %end = icmp eq i64 %i.next, %len
  br i1 %end, label %filled, label %loop

filled:
  call fastcc void @julia_copyout(ptr addrspace(10) nocapture noundef nonnull readonly align 16 dereferenceable(40) %v6, ptr addrspace(10) nocapture noundef nonnull readonly align 16 dereferenceable(40) %y)
  %r = call fastcc double @julia_sum_ratio(ptr addrspace(10) %v6, ptr addrspace(10) %w)
  ret double %r
}

; Function Attrs: noinline readonly
define internal fastcc double @julia_sum_ratio(ptr addrspace(10) nocapture nofree noundef nonnull readonly align 16 dereferenceable(40) "enzyme_type"="{[-1]:Pointer, [-1,0]:Pointer, [-1,0,-1]:Float@double, [-1,8]:Integer, [-1,9]:Integer, [-1,10]:Integer, [-1,11]:Integer, [-1,12]:Integer, [-1,13]:Integer, [-1,14]:Integer, [-1,15]:Integer}" %t, ptr addrspace(10) nocapture nofree noundef nonnull readonly align 16 dereferenceable(40) "enzyme_type"="{[-1]:Pointer, [-1,0]:Pointer, [-1,0,-1]:Float@double, [-1,8]:Integer, [-1,9]:Integer, [-1,10]:Integer, [-1,11]:Integer, [-1,12]:Integer, [-1,13]:Integer, [-1,14]:Integer, [-1,15]:Integer}" %w) unnamed_addr #2 {
top:
  %ta = addrspacecast ptr addrspace(10) %t to ptr addrspace(11)
  %len_ptr = getelementptr inbounds { ptr addrspace(13), i64, i16, i16, i32 }, ptr addrspace(11) %ta, i64 0, i32 1
  %len = load i64, ptr addrspace(11) %len_ptr, align 8, !tbaa !0, !enzyme_inactive !5, !enzyme_type !6
  %empty = icmp eq i64 %len, 0
  br i1 %empty, label %done, label %pre

pre:
  %td = load ptr addrspace(13), ptr addrspace(11) %ta, align 8, !tbaa !8, !enzyme_type !10
  %wa = addrspacecast ptr addrspace(10) %w to ptr addrspace(11)
  %wd = load ptr addrspace(13), ptr addrspace(11) %wa, align 16, !tbaa !8, !enzyme_type !10
  br label %loop

loop:
  %i = phi i64 [ 0, %pre ], [ %i.next, %loop ]
  %acc = phi double [ 0.000000e+00, %pre ], [ %acc.next, %loop ]
  %tp = getelementptr inbounds double, ptr addrspace(13) %td, i64 %i
  %tv = load double, ptr addrspace(13) %tp, align 8, !tbaa !13, !enzyme_type !16
  %sq = fmul double %tv, %tv
  %wp = getelementptr inbounds double, ptr addrspace(13) %wd, i64 %i
  %wv = load double, ptr addrspace(13) %wp, align 8, !tbaa !13, !enzyme_type !16
  %q = fdiv double %sq, %wv
  %acc.next = fadd double %acc, %q
  %i.next = add nuw nsw i64 %i, 1
  %end = icmp eq i64 %i.next, %len
  br i1 %end, label %done, label %loop

done:
  %res = phi double [ 0.000000e+00, %top ], [ %acc.next, %loop ]
  ret double %res
}

attributes #0 = { mustprogress nofree nounwind willreturn "enzyme_no_escaping_allocation" }
attributes #1 = { noinline }
attributes #2 = { noinline readonly }

!0 = !{!1, !1, i64 0}
!1 = !{!"jtbaa_arraylen", !2, i64 0}
!2 = !{!"jtbaa_array", !3, i64 0}
!3 = !{!"jtbaa", !4, i64 0}
!4 = !{!"jtbaa"}
!5 = !{}
!6 = !{!"Unknown", i32 -1, !7}
!7 = !{!"Integer"}
!8 = !{!9, !9, i64 0}
!9 = !{!"jtbaa_arrayptr", !2, i64 0}
!10 = !{!"Unknown", i32 -1, !11}
!11 = !{!"Pointer", i32 -1, !12}
!12 = !{!"Float@double"}
!13 = !{!14, !14, i64 0}
!14 = !{!"jtbaa_arraybuf", !15, i64 0}
!15 = !{!"jtbaa_data", !3, i64 0}
!16 = !{!"Unknown", i32 -1, !12}

; The array julia_fill writes is kept for the reverse pass (its pointer is on
; the tape), not allocated again.
; CHECK: define internal fastcc void @diffejulia_mid_fill(
; CHECK-NOT: @julia.gc_alloc_obj(ptr null, i64 40
; CHECK: call fastcc {{.*}} @diffejulia_sum_ratio(ptr addrspace(10) {{.*}}%v6
; CHECK: ret void

; The array mid_copy fills itself is rematerialized with its fill loop, as in
; julia_array_data_remat.ll, although julia_copyout writes memory: it writes
; only the storage of its other argument (getArgumentOwnedStorageWrites).
; CHECK: define internal fastcc void @diffejulia_mid_copy(
; CHECK: %v6 = call noalias nonnull {{.*}}ptr addrspace(10) @julia.gc_alloc_obj(ptr null, i64 40, ptr addrspace(10) null)
; CHECK: store double %tv, ptr addrspace(13) %tp, align 8
; CHECK: ret void
