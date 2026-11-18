; RUN: if [ %llvmver -ge 15 ] && [ %llvmver -lt 17 ]; then %opt < %s %OPnewLoadEnzyme -opaque-pointers=0 -enzyme-preopt=false -enzyme-julia-addr-load -passes="enzyme" -S | FileCheck %s; fi

; A locally read-only callee can fill newly allocated memory and return it.
; Returning that result, directly or in an aggregate, makes the writes visible
; outside the caller. Calling the wrapper fully read-only lets reverse AD
; discard the shadow of the input the allocation was filled from.
; Put callers before their callees to also cover pending call classification.

declare noalias i8* @malloc(i64)
declare double** @make_header(double*) "enzyme_LocalReadOnlyOrThrow"

define double* @outer(double* %x) {
  %p = call double* @wrapper(double* %x)
  ret double* %p
}

define double* @wrapper(double* %x) {
  %p = call double* @fill(double* %x)
  ret double* %p
}

define { double*, i64 } @aggregate(double* %x) {
  %p = call double* @fill(double* %x)
  %r = insertvalue { double*, i64 } undef, double* %p, 0
  %s = insertvalue { double*, i64 } %r, i64 1, 1
  ret { double*, i64 } %s
}

define double @consume_locally(double* %x) {
  ; A used result conservatively retains the local classification. A capture
  ; proof of the result alone cannot distinguish this from return_pointee.
  %p = call double* @fill(double* %x)
  %v = load double, double* %p
  ret double %v
}

define double* @return_pointee(double* %x) {
  %header = call double** @make_header(double* %x)
  %p = load double*, double** %header
  ret double* %p
}

define void @discard_result(double* %x) {
  %p = call double* @fill(double* %x)
  ret void
}

define double* @fill(double* %x) {
  %raw = call noalias i8* @malloc(i64 8)
  %p = bitcast i8* %raw to double*
  %v = load double, double* %x
  store double %v, double* %p
  ret double* %p
}

; CHECK: define double* @outer(double* {{.*}}%x) #[[LOCAL:[0-9]+]]
; CHECK: define double* @wrapper(double* {{.*}}%x) #[[LOCAL]]
; CHECK: define { double*, i64 } @aggregate(double* {{.*}}%x) #[[LOCAL]]
; CHECK: define double @consume_locally(double* {{.*}}%x) #[[LOCAL]]
; CHECK: define double* @return_pointee(double* {{.*}}%x) #[[LOCAL]]
; CHECK: define void @discard_result(double* {{.*}}%x) #[[READONLY:[0-9]+]]
; CHECK: define double* @fill(double* {{.*}}%x) #[[LOCAL]]
; CHECK: attributes #[[LOCAL]] = { {{.*}}"enzyme_LocalReadOnlyOrThrow" }
; CHECK: attributes #[[READONLY]] = { {{.*}}"enzyme_ReadOnlyOrThrow" }
