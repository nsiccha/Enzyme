; RUN: %opt %newLoadEnzyme -S -passes=enzyme-fixup-julia < %s 2>&1 | FileCheck %s

; The sret holds a tracked pointer to something other than a Julia value, as a
; tape holding a garbage-collected cache does. Its root slot has the type of a
; Julia value, so with typed pointers the pointer is cast before it is stored.
; Without the cast the module fails verification: "Stored value type does not
; match pointer operand type!".

; CHECK-NOT: Stored value type does not match
; CHECK-LABEL: define internal void @callee(
; CHECK: [[LOADED:%[0-9]+]] = load i8 addrspace(10)*, i8 addrspace(10)** {{%[0-9]+}}
; CHECK-NEXT: [[CAST:%[0-9]+]] = bitcast i8 addrspace(10)* [[LOADED]] to {} addrspace(10)*
; CHECK-NEXT: store {} addrspace(10)* [[CAST]], {} addrspace(10)** {{%[0-9]+}}

define i64 @caller(i8 addrspace(10)* %v) {
entry:
  %sret = alloca { i8 addrspace(10)*, i64 }, align 8
  call void @callee({ i8 addrspace(10)*, i64 }* "enzyme_sret"="test_type7" %sret, i8 addrspace(10)* %v)
  %kp = getelementptr inbounds { i8 addrspace(10)*, i64 }, { i8 addrspace(10)*, i64 }* %sret, i64 0, i32 1
  %k = load i64, i64* %kp, align 8
  ret i64 %k
}

define internal void @callee({ i8 addrspace(10)*, i64 }* noalias writeonly "enzyme_sret"="test_type7" %sret, i8 addrspace(10)* %v) {
entry:
  %p = getelementptr inbounds { i8 addrspace(10)*, i64 }, { i8 addrspace(10)*, i64 }* %sret, i64 0, i32 0
  store i8 addrspace(10)* %v, i8 addrspace(10)** %p, align 8
  %k = getelementptr inbounds { i8 addrspace(10)*, i64 }, { i8 addrspace(10)*, i64 }* %sret, i64 0, i32 1
  store i64 7, i64* %k, align 8
  ret void
}
