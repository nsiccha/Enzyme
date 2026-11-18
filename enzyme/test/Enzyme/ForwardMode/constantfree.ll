; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -enzyme-preopt=false -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-preopt=false -S | FileCheck %s

; Integer loop caches in a reverse pass have no shadow in an outer forward
; derivative. Their primal storage must still be released. Exercise both an
; ordinary deallocation and a cache free through a pointer loaded from a tape.

declare double @__enzyme_fwddiff(...)
declare void @free(i8*)

define double @constant_free(i64* %p, double %x) {
  %n = load i64, i64* %p
  %a = sitofp i64 %n to double
  %r = fmul double %a, %x
  %q = bitcast i64* %p to i8*
  call void @free(i8* %q)
  ret double %r
}

define double @constant_cache_free(i64** %tape, double %x) {
  %p = load i64*, i64** %tape
  %n = load i64, i64* %p
  %a = sitofp i64 %n to double
  %r = fmul double %a, %x
  %q = bitcast i64* %p to i8*
  call void @free(i8* %q), !enzyme_cache_free !0
  ret double %r
}

define double @dconstant_free(i64* %p, double %x, double %dx) {
  %r = call double (...) @__enzyme_fwddiff(double (i64*, double)* @constant_free, metadata !"enzyme_const", i64* %p, double %x, double %dx)
  ret double %r
}

define double @dconstant_cache_free(i64** %tape, double %x, double %dx) {
  %r = call double (...) @__enzyme_fwddiff(double (i64**, double)* @constant_cache_free, metadata !"enzyme_const", i64** %tape, double %x, double %dx)
  ret double %r
}

; CHECK-LABEL: define internal double @fwddiffeconstant_free(
; CHECK: %[[Q:.*]] = bitcast i64* %p to i8*
; CHECK-NEXT: call void @free(i8* %[[Q]])
; CHECK-NEXT: ret double

; CHECK-LABEL: define internal double @fwddiffeconstant_cache_free(
; CHECK: %[[P:.*]] = load i64*, i64** %tape
; CHECK: %[[Q:.*]] = bitcast i64* %[[P]] to i8*
; CHECK-NEXT: call void @free(i8* %[[Q]])
; CHECK-NEXT: ret double

!0 = !{}
