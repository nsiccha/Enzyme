; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="print-type-analysis" -type-analysis-func=boxed -S -o /dev/null | FileCheck %s; fi
;
; An abstract Julia array stores pointers to objects of different types. The
; pointer loaded after the second store can have an integer field even though
; the first object has a floating-point field at the same offset.
declare void @use_float(ptr addrspace(10) "enzyme_type"="{[-1]:Pointer, [-1,0]:Float@double}")
declare void @use_integer(ptr addrspace(10) "enzyme_type"="{[-1]:Pointer, [-1,0]:Integer}")

define void @boxed(ptr addrspace(13) %slot, ptr addrspace(10) %a, ptr addrspace(10) %b) {
entry:
  call void @use_float(ptr addrspace(10) %a)
  store ptr addrspace(10) %a, ptr addrspace(13) %slot, !enzyme_opaque_element !0
  store ptr addrspace(10) %b, ptr addrspace(13) %slot, !enzyme_opaque_element !0
  %read = load ptr addrspace(10), ptr addrspace(13) %slot, !enzyme_opaque_element !0
  call void @use_integer(ptr addrspace(10) %read)
  ret void
}
!0 = !{}

; CHECK: ptr addrspace(13) %slot: {[-1]:Pointer, [-1,0]:Pointer}
; CHECK: ptr addrspace(10) %a: {[-1]:Pointer, [-1,0]:Float@double}
; CHECK: ptr addrspace(10) %b: {[-1]:Pointer}
; CHECK: %read = load {{.*}}: {[-1]:Pointer, [-1,0]:Integer}
