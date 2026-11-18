; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -enzyme-preopt=false -S | FileCheck %s; fi
; RUN: if [ %llvmver -lt 17 ]; then %opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-preopt=false -S | FileCheck %s; fi

; A stack slot of a function differentiated as a callee moves to the heap.
; With typed pointers an addrspacecast may also change the pointee type, as
; Julia's `addrspacecast T* %slot to i8 addrspace(11)*` for jl_object_id_
; does. Where the moved slot is already in the cast's address space, its uses
; must get a bitcast of the new allocation to the cast's type: the
; allocation's own type made a call that failed verification.

target datalayout = "e-m:e-i64:64-n32:64-A5"

declare i64 @hash_bytes(i8* nocapture readonly) "enzyme_inactive" readonly nofree nounwind willreturn

define double @callee(double %x) {
entry:
  %slot = alloca { double, double }, align 8, addrspace(5)
  %f0 = getelementptr inbounds { double, double }, { double, double } addrspace(5)* %slot, i64 0, i32 0
  store double %x, double addrspace(5)* %f0, align 8
  %f1 = getelementptr inbounds { double, double }, { double, double } addrspace(5)* %slot, i64 0, i32 1
  store double 2.0, double addrspace(5)* %f1, align 8
  %whole = addrspacecast { double, double } addrspace(5)* %slot to i8*
  %h0 = call i64 @hash_bytes(i8* %whole)
  %second = addrspacecast double addrspace(5)* %f1 to i8*
  %h1 = call i64 @hash_bytes(i8* %second)
  %same = icmp eq i64 %h0, %h1
  %ld = load double, double addrspace(5)* %f0, align 8
  %sq = fmul double %ld, %ld
  %res = select i1 %same, double %x, double %sq
  ret double %res
}

define double @outer(double %x) {
entry:
  %m = call double @callee(double %x)
  %r = fmul double %m, %x
  ret double %r
}

declare double @__enzyme_autodiff(i8*, double)

define double @test(double %x) {
entry:
  %r = call double @__enzyme_autodiff(i8* bitcast (double (double)* @outer to i8*), double %x)
  ret double %r
}

; CHECK: define internal { i1, double } @augmented_callee(double %x)
; CHECK: %[[slot:[^ ]+]] = bitcast i8* %{{[^ ]+}} to { double, double }*, !enzyme_caststack
; CHECK: %[[whole:[^ ]+]] = bitcast { double, double }* %[[slot]] to i8*
; CHECK-NEXT: %h0 = call i64 @hash_bytes(i8* %[[whole]])
; CHECK-NEXT: %[[second:[^ ]+]] = bitcast double* %f1 to i8*
; CHECK-NEXT: %h1 = call i64 @hash_bytes(i8* %[[second]])
