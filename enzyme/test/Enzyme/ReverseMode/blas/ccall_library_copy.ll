; RUN: %opt < %s %newLoadEnzyme -passes="enzyme" -S | FileCheck %s
;
; Two providers implement the same BLAS ABI. Writing the inputs after the dots
; forces the reverse rule to copy them. Each copy and adjoint must name the
; provider of its own primal, even in the same derivative.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

declare double @"ejlrt$cblas_ddot$A"(i32, double*, i32, double*, i32) #0
declare double @"ejlrt$cblas_ddot$B"(i32, double*, i32, double*, i32) #0
declare void @__enzyme_autodiff(...)

define double @two_dots(i32 %n, double* %x, double* %y, i32 %stride) {
  %a = call double @"ejlrt$cblas_ddot$A"(i32 %n, double* %x, i32 %stride, double* %y, i32 %stride)
  %b = call double @"ejlrt$cblas_ddot$B"(i32 %n, double* %x, i32 %stride, double* %y, i32 %stride)
  store double 0.0, double* %x
  store double 0.0, double* %y
  %sum = fadd double %a, %b
  ret double %sum
}

define void @gradient(i32 %n, double* %x, double* %dx, double* %y, double* %dy, i32 %stride) {
  call void (...) @__enzyme_autodiff(double (i32, double*, double*, i32)* @two_dots, i32 %n, double* %x, double* %dx, double* %y, double* %dy, i32 %stride)
  ret void
}

attributes #0 = { "enzyme_math"="cblas_ddot" }

; CHECK-DAG: call void @"ejlrt$cblas_dcopy$A"(
; CHECK-DAG: call void @"ejlrt$cblas_dcopy$B"(
; CHECK-DAG: call void @"ejlrt$cblas_daxpy$A"(
; CHECK-DAG: call void @"ejlrt$cblas_daxpy$B"(
