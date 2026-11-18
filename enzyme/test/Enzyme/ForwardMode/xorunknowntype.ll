; RUN: if [ %llvmver -lt 16 ]; then (%opt < %s %loadEnzyme -enzyme -enzyme-preopt=false -S 2>&1 || true) | FileCheck %s; fi
; RUN: (%opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-preopt=false -S 2>&1 || true) | FileCheck %s

; The result of this xor has no known type, so it is not a sign-bit flip of a
; float. The forward rule must report that instead of crashing on the missing
; type.

define void @tester(double %x, i64* %out) {
entry:
  %cst = bitcast double %x to i64
  %flip = xor i64 %cst, 1
  store i64 %flip, i64* %out
  ret void
}

define void @test_derivative(double %x, double %dx, i64* %out, i64* %dout) {
entry:
  call void (void (double, i64*)*, ...) @__enzyme_fwddiff(void (double, i64*)* nonnull @tester, metadata !"enzyme_dup", double %x, double %dx, metadata !"enzyme_dup", i64* %out, i64* %dout)
  ret void
}

declare void @__enzyme_fwddiff(void (double, i64*)*, ...)

; CHECK: cannot handle unknown binary operator: {{.*}}%flip = xor i64 %cst, 1
