; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -enzyme-preopt=false -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-preopt=false -S | FileCheck %s

; A reverse pass reads a length back from its tape and computes a count from it,
; as the reverse of resize! does. The tape is active in the outer forward pass,
; so only the type on the read says that the length is an integer. Without it
; the xor counts as active, and has no derivative. With it neither the xor nor
; the add needs a shadow.

define void @tester(i64* %out, { i64, double } %tape) {
entry:
  %len = extractvalue { i64, double } %tape, 0, !enzyme_type !0
  %flip = xor i64 %len, -1
  %count = add i64 %flip, 7
  store i64 %count, i64* %out, align 8
  ret void
}

define void @test_derivative(i64* %out, i64* %dout, { i64, double } %tape, { i64, double } %dtape) {
entry:
  call void (void (i64*, { i64, double })*, ...) @__enzyme_fwddiff(void (i64*, { i64, double })* nonnull @tester, metadata !"enzyme_dup", i64* %out, i64* %dout, metadata !"enzyme_dup", { i64, double } %tape, { i64, double } %dtape)
  ret void
}

declare void @__enzyme_fwddiff(void (i64*, { i64, double })*, ...)

!0 = !{!"Unknown", i32 -1, !1}
!1 = !{!"Integer"}

; CHECK: define internal void @fwddiffetester(
; CHECK: %flip = xor i64 %len, -1
; CHECK-NEXT: %count = add i64 %flip, 7
; CHECK-NOT: %"flip'"
; CHECK-NOT: %"count'"
