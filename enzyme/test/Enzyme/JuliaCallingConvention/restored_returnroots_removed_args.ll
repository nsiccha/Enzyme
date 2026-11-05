; RUN: %opt %newLoadEnzyme -S -passes=enzyme-fixup-julia-sret < %s | FileCheck %s
; RUN: %opt %newLoadEnzyme -S -passes=enzyme-fixup-julia < %s | FileCheck %s

; Restoring the returnRoots removed from a Julia sret function also restores
; original ABI argument 1 in enzyme_parmremove. Other removed indexes still
; refer to the original ABI and must neither be dropped nor renumbered.
; A function whose returnRoots already exists keeps its removal metadata.

; CHECK-DAG: define void @only_roots({{.*}} sret({ {{.*}} }) %0, {{.*}} "enzymejl_returnRoots"="1" %1, {{.*}} %v) #[[ONLY:[0-9]+]]
; CHECK-DAG: define void @other_removed({{.*}} sret({ {{.*}} }) %0, {{.*}} "enzymejl_returnRoots"="1" %1, {{.*}} %v, i64 %k) #[[OTHER:[0-9]+]]
; CHECK-DAG: define void @existing_roots({{.*}} sret({ {{.*}} }) %sret, {{.*}} "enzymejl_returnRoots"="1" %roots, {{.*}} %v) #[[EXISTING:[0-9]+]]
; CHECK-DAG: attributes #[[ONLY]] = { noinline }
; CHECK-DAG: attributes #[[OTHER]] = { noinline "enzyme_parmremove"="3,5" }
; CHECK-DAG: attributes #[[EXISTING]] = { noinline "enzyme_parmremove"="3" }

define void @only_roots({ {} addrspace(10)*, i64 }* sret({ {} addrspace(10)*, i64 }) %sret, {} addrspace(10)* %v) #0 {
entry:
  %p = getelementptr inbounds { {} addrspace(10)*, i64 }, { {} addrspace(10)*, i64 }* %sret, i64 0, i32 0
  store {} addrspace(10)* %v, {} addrspace(10)** %p, align 8
  %k = getelementptr inbounds { {} addrspace(10)*, i64 }, { {} addrspace(10)*, i64 }* %sret, i64 0, i32 1
  store i64 7, i64* %k, align 8
  ret void
}

define void @other_removed({ {} addrspace(10)*, i64 }* sret({ {} addrspace(10)*, i64 }) %sret, {} addrspace(10)* %v, i64 %k) #1 {
entry:
  %p = getelementptr inbounds { {} addrspace(10)*, i64 }, { {} addrspace(10)*, i64 }* %sret, i64 0, i32 0
  store {} addrspace(10)* %v, {} addrspace(10)** %p, align 8
  %kp = getelementptr inbounds { {} addrspace(10)*, i64 }, { {} addrspace(10)*, i64 }* %sret, i64 0, i32 1
  store i64 %k, i64* %kp, align 8
  ret void
}

define void @existing_roots({ {} addrspace(10)*, i64 }* sret({ {} addrspace(10)*, i64 }) %sret, [1 x {} addrspace(10)*]* "enzymejl_returnRoots"="1" %roots, {} addrspace(10)* %v) #2 {
entry:
  %p = getelementptr inbounds { {} addrspace(10)*, i64 }, { {} addrspace(10)*, i64 }* %sret, i64 0, i32 0
  store {} addrspace(10)* %v, {} addrspace(10)** %p, align 8
  %r = getelementptr inbounds [1 x {} addrspace(10)*], [1 x {} addrspace(10)*]* %roots, i64 0, i64 0
  store {} addrspace(10)* %v, {} addrspace(10)** %r, align 8
  ret void
}

attributes #0 = { noinline "enzyme_parmremove"="1" }
attributes #1 = { noinline "enzyme_parmremove"="1,3,5" }
attributes #2 = { noinline "enzyme_parmremove"="3" }
