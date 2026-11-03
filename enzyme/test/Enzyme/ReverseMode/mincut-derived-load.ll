; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-julia-addr-load -passes="enzyme" -S | FileCheck %s; fi

; The element loaded in the loop can be recomputed in the reverse pass, but both
; the array it is read from and the index need caching, as later stores
; overwrite them. So the cheapest cut is the element's address, which cannot be
; cached. Its base is a load of the array's data pointer, which cannot be cached
; either but can be recomputed from the cached array.

declare void @__enzyme_autodiff(...)

define double @f(ptr addrspace(13) %arrays, ptr addrspace(13) %idxs, double %x, i64 %n) {
entry:
  %array = load ptr addrspace(10), ptr addrspace(13) %arrays, !tbaa !0
  %idx = load i64, ptr addrspace(13) %idxs, !tbaa !3
  %header = addrspacecast ptr addrspace(10) %array to ptr addrspace(11)
  %data = load ptr addrspace(13), ptr addrspace(11) %header, !tbaa !5
  %elem = getelementptr inbounds double, ptr addrspace(13) %data, i64 %idx
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %inc, %loop ]
  %acc = phi double [ 0.0, %entry ], [ %acc.next, %loop ]
  %y = load double, ptr addrspace(13) %elem, !tbaa !7
  %d = fsub double %y, %x
  %sq = fmul double %d, %d
  %acc.next = fadd double %acc, %sq
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop

exit:
  store i64 0, ptr addrspace(13) %idxs, !tbaa !3
  store ptr addrspace(10) null, ptr addrspace(13) %arrays, !tbaa !0
  ret double %acc.next
}

define void @test(ptr addrspace(13) %arrays, ptr addrspace(13) %idxs, double %x, i64 %n) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr addrspace(13) %arrays, metadata !"enzyme_const", ptr addrspace(13) %idxs, double %x, metadata !"enzyme_const", i64 %n)
  ret void
}

!0 = !{!1, !1, i64 0}
!1 = !{!"jtbaa_ptrarraybuf", !2, i64 0}
!2 = !{!"jtbaa"}
!3 = !{!4, !4, i64 0}
!4 = !{!"jtbaa_longarraybuf", !2, i64 0}
!5 = !{!6, !6, i64 0}
!6 = !{!"jtbaa_arrayptr", !2, i64 0}
!7 = !{!8, !8, i64 0}
!8 = !{!"jtbaa_doublearraybuf", !2, i64 0}

; CHECK: define internal { double } @diffef(
; CHECK: %array = load ptr addrspace(10), ptr addrspace(13) %arrays
; CHECK: %idx = load i64, ptr addrspace(13) %idxs
; CHECK: %elem = getelementptr inbounds double, ptr addrspace(13) %data, i64 %idx
; CHECK-NOT: malloc
; CHECK: invertloop:
; CHECK: %y_unwrap = load double, ptr addrspace(13) %elem
; CHECK-NEXT: %d_unwrap = fsub double %y_unwrap, %x
