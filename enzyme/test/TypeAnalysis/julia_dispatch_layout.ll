; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="print-type-analysis" -type-analysis-func=dispatch -S -o /dev/null | FileCheck %s; fi
; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="print-type-analysis" -type-analysis-func=unrelated -S -o /dev/null | FileCheck %s --check-prefix=UNRELATED; fi
;
; A runtime type check selects the concrete layout of the same Julia reference.
@float_type = external addrspace(10) global i8
declare ptr addrspace(10) @julia.typeof(ptr addrspace(10))
declare void @use_float(ptr addrspace(11) "enzyme_type"="{[-1]:Pointer, [-1,0]:Float@double}")
declare void @use_integer(ptr addrspace(11) "enzyme_type"="{[-1]:Pointer, [-1,0]:Integer}")

define void @dispatch(ptr addrspace(10) %obj) {
entry:
  %type = call ptr addrspace(10) @julia.typeof(ptr addrspace(10) %obj)
  %isfloat = icmp eq ptr addrspace(10) %type, @float_type
  br i1 %isfloat, label %floats, label %integers
floats:
  %a = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  call void @use_float(ptr addrspace(11) %a)
  ret void
integers:
  %b = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  call void @use_integer(ptr addrspace(11) %b)
  ret void
}

; CHECK: %a = addrspacecast {{.*}}: {[-1]:Pointer, [-1,0]:Float@double}
; CHECK: %b = addrspacecast {{.*}}: {[-1]:Pointer, [-1,0]:Integer}

; A nearby typeof which does not control the branch leaves type flow intact.
declare void @observe(ptr addrspace(10))
declare void @use_box(ptr addrspace(10) "enzyme_type"="{[-1]:Pointer, [-1,0]:Float@double}")
declare void @use_pointer(ptr addrspace(11))
define void @unrelated(ptr addrspace(10) %obj, i1 %condition) {
entry:
  call void @use_box(ptr addrspace(10) %obj)
  %type = call ptr addrspace(10) @julia.typeof(ptr addrspace(10) %obj)
  call void @observe(ptr addrspace(10) %type)
  br i1 %condition, label %visit, label %end
visit:
  %a = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
  call void @use_pointer(ptr addrspace(11) %a)
  br label %end
end:
  ret void
}
; UNRELATED: %a = addrspacecast {{.*}}: {[-1]:Pointer, [-1,0]:Float@double}
