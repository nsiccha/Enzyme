; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -enzyme-runtime-error -passes="enzyme,function(mem2reg,simplifycfg)" -S | FileCheck %s

; A constant function pointer can consume an active scalar or active memory.
; It has no shadow function with Enzyme's indirect derivative ABI. Diagnose
; before classifying all pointer arguments as duplicated (including inactive
; allocations used for error/status outputs).

define double @scalar(ptr %fn, double %x) {
  %r = call double %fn(double %x) nounwind nofree readnone
  ret double %r
}

define double @buffer(ptr %fn, ptr %x) {
  %out = alloca double
  %err = alloca ptr
  store double 0.0, ptr %out
  store ptr null, ptr %err
  %status = call i32 %fn(ptr %x, ptr %out, ptr %err) nounwind nofree
  %r = load double, ptr %out
  ret double %r
}

define double @inactive(ptr %fn, double %x, double %y) {
  %r = call double %fn(double %y) nounwind nofree readnone
  %xx = fmul double %x, %x
  %result = fadd double %xx, %r
  ret double %result
}

declare double @__enzyme_autodiff(...)
declare double @__enzyme_fwddiff(...)
declare { ptr, double } @__enzyme_augmentfwd(...)

define double @reverse_scalar(ptr %fn, double %x) {
  %r = call double (...) @__enzyme_autodiff(ptr @scalar, metadata !"enzyme_const", ptr %fn, double %x)
  ret double %r
}

define double @forward_scalar(ptr %fn, double %x, double %dx) {
  %r = call double (...) @__enzyme_fwddiff(ptr @scalar, metadata !"enzyme_const", ptr %fn, double %x, double %dx)
  ret double %r
}

define void @reverse_buffer(ptr %fn, ptr %x, ptr %dx) {
  call void (...) @__enzyme_autodiff(ptr @buffer, metadata !"enzyme_const", ptr %fn, ptr %x, ptr %dx)
  ret void
}

define double @forward_buffer(ptr %fn, ptr %x, ptr %dx) {
  %r = call double (...) @__enzyme_fwddiff(ptr @buffer, metadata !"enzyme_const", ptr %fn, ptr %x, ptr %dx)
  ret double %r
}

define double @reverse_inactive(ptr %fn, double %x, double %y) {
  %r = call double (...) @__enzyme_autodiff(ptr @inactive, metadata !"enzyme_const", ptr %fn, double %x, metadata !"enzyme_const", double %y)
  ret double %r
}

define { ptr, double } @augment_buffer(ptr %fn, ptr %x, ptr %dx) {
  %result = call { ptr, double } (...) @__enzyme_augmentfwd(ptr @buffer, metadata !"enzyme_const", ptr %fn, ptr %x, ptr %dx)
  ret { ptr, double } %result
}

; CHECK: No derivative available for indirect call through an inactive function pointer
; CHECK-LABEL: define internal {{.*}} @diffescalar(
; CHECK: call void @exit(i32 1)
; CHECK-LABEL: define internal {{.*}} @fwddiffescalar(
; CHECK: call void @exit(i32 1)
; CHECK-LABEL: define internal {{.*}} @diffebuffer(
; CHECK: call void @exit(i32 1)
; CHECK-LABEL: define internal {{.*}} @fwddiffebuffer(
; CHECK: call void @exit(i32 1)
; CHECK-LABEL: define internal {{.*}} @diffeinactive(
; CHECK-NOT: @exit
; CHECK: fmul fast double {{.*}}, %x
; CHECK: ret
; CHECK-LABEL: define internal {{.*}} @augmented_buffer(
; CHECK-NOT: @exit
; CHECK: call i32 %fn(
; CHECK-NOT: @exit
; CHECK: ret
