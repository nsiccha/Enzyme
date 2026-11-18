; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="print-type-analysis" -type-analysis-func=choose -S -o /dev/null | FileCheck %s; fi
;
; The leaf and internal node of a persistent tree have different layouts.
; Only the node arm has an integer field. A read through the joined pointer
; guarded by the original branch condition must not type the leaf as a node.
@leaf = external addrspace(10) global i8
@node = external addrspace(10) global i8
declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10))
declare void @use_float(ptr addrspace(10) "enzyme_type"="{[-1]:Pointer, [-1,0]:Float@double}")
declare void @use_integer(ptr addrspace(10) "enzyme_type"="{[-1]:Pointer, [-1,0]:Integer}")

define void @choose(i1 %cond) {
entry:
  br i1 %cond, label %left, label %right
left:
  %a = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr null, i64 8, ptr addrspace(10) @leaf)
  call void @use_float(ptr addrspace(10) %a)
  br label %join
right:
  %b = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr null, i64 8, ptr addrspace(10) @node)
  call void @use_integer(ptr addrspace(10) %b)
  br label %join
join:
  %obj = phi ptr addrspace(10) [ %a, %left ], [ %b, %right ]
  br i1 %cond, label %end, label %read_node
read_node:
  call void @use_integer(ptr addrspace(10) %obj)
  br label %end
end:
  ret void
}

; CHECK: %a = call {{.*}}: {[-1]:Pointer, [-1,-1]:Float@double}
; CHECK: %b = call {{.*}}: {[-1]:Pointer, [-1,0]:Integer}
; CHECK: %obj = phi {{.*}}: {[-1]:Pointer, [-1,0]:Integer}
