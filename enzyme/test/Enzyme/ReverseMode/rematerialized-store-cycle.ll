; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme" -enzyme-preopt=false -enzyme-julia-addr-load -S | FileCheck %s; fi

; Recreating %arr for the branch on its length also preserves the stores into
; its data. Recursive use analysis visits a cycle through those stores and can
; leave %arr provisionally unused even after discovering the required length.
; The cache graph must still connect %v to that required load. Previously it
; dropped %arr, marked %v unused, and erased @g with a surviving store operand.

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128-ni:10:11:12:13"
target triple = "x86_64-linux-gnu"

declare noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr, i64, ptr addrspace(10)) inaccessiblememonly

define void @f(double %x, ptr %a, i64 %count) noinline {
entry:
  %arr = call noalias ptr addrspace(10) @julia.gc_alloc_obj(ptr null, i64 64, ptr addrspace(10) null)
  %arr11 = addrspacecast ptr addrspace(10) %arr to ptr addrspace(11)
  %lenptr = getelementptr i8, ptr addrspace(11) %arr11, i64 8
  %n = load i64, ptr addrspace(11) %lenptr
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %start, label %zero
zero:
  %zero_data = load ptr addrspace(13), ptr addrspace(11) %arr11
  %bytes = shl i64 %n, 3
  call void @llvm.memset.p13.i64(ptr addrspace(13) %zero_data, i8 0, i64 %bytes, i1 false)
  br label %start
start:
  %none = icmp eq i64 %count, 0
  br i1 %none, label %exit, label %loop
loop:
  %i = phi i64 [0, %start], [%next, %loop]
  %v = call double @g(double %x, ptr %a)
  %data = load ptr addrspace(13), ptr addrspace(11) %arr11
  %dest = getelementptr double, ptr addrspace(13) %data, i64 %i
  %w = fmul double %v, %x
  store double %w, ptr addrspace(13) %dest
  %next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %next, %count
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define double @g(double %x, ptr nocapture readonly %a) noinline readonly {
  %v = load double, ptr %a
  %w = fmul double %x, %v
  ret double %w
}

declare void @llvm.memset.p13.i64(ptr addrspace(13), i8, i64, i1)
declare double @__enzyme_reverse(...)
define double @driver(double %x, ptr %a, ptr %da, i64 %count, ptr %tape) {
  %dx = call double (...) @__enzyme_reverse(ptr @f, double %x, ptr %a, ptr %da, i64 %count, ptr %tape)
  ret double %dx
}

; CHECK-LABEL: define internal ptr @augmented_f(
; CHECK: %arr = call noalias ptr addrspace(10) @julia.gc_alloc_obj
; CHECK: store ptr addrspace(10) %arr, ptr
; CHECK: call double @{{(nofree_)?}}g(

; CHECK-LABEL: define internal { double } @diffef(
; CHECK: %arr = load ptr addrspace(10), ptr %tapeArg
; CHECK-NOT: @julia.gc_alloc_obj
; CHECK-NOT: call double @{{(nofree_)?}}g(
; CHECK-NOT: store double %w
; CHECK: ret { double }
