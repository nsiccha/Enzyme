; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -enzyme-preopt=false -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-preopt=false -S | FileCheck %s

; A pair of floats (a ComplexF32) copied as one i64, as SROA emits it: one
; path unpacks the upper float with lshr 32, the other computes it as a float,
; and the merged halves are packed again with zext, shl 32 and or. Type
; analysis has to see the shifted halves as floats for the shl to have a
; derivative.
define void @tester(float* %src, i64* %dst, i1 %c) {
entry:
  %srci = bitcast float* %src to i64*
  br i1 %c, label %copy, label %neg
copy:
  %ld = load i64, i64* %srci, align 4
  %lo.c = trunc i64 %ld to i32
  %hi.sh = lshr i64 %ld, 32
  %hi.c = trunc i64 %hi.sh to i32
  br label %join
neg:
  %re = load float, float* %src, align 4
  %ip = getelementptr inbounds float, float* %src, i64 1
  %im = load float, float* %ip, align 4
  %nim = fneg float %im
  %lo.n = bitcast float %re to i32
  %hi.n = bitcast float %nim to i32
  br label %join
join:
  %hi = phi i32 [ %hi.c, %copy ], [ %hi.n, %neg ]
  %lo = phi i32 [ %lo.c, %copy ], [ %lo.n, %neg ]
  %hi.ext = zext i32 %hi to i64
  %hi.shl = shl nuw i64 %hi.ext, 32
  %lo.ext = zext i32 %lo to i64
  %pack = or i64 %hi.shl, %lo.ext
  store i64 %pack, i64* %dst, align 4
  ret void
}

define void @test_derivative(float* %src, float* %dsrc, i64* %dst, i64* %ddst, i1 %c) {
entry:
  call void (...) @__enzyme_autodiff(void (float*, i64*, i1)* @tester, metadata !"enzyme_dup", float* %src, float* %dsrc, metadata !"enzyme_dup", i64* %dst, i64* %ddst, metadata !"enzyme_const", i1 %c)
  ret void
}

declare void @__enzyme_fwddiff(...)
declare void @__enzyme_autodiff(...)

; CHECK: define internal void @diffetester(
; CHECK: invertcopy:
; CHECK: store i32 0, i32* %"hi.c'de"
; CHECK-NEXT: %[[dsh:.+]] = load i64, i64* %"hi.sh'de"
; CHECK-NEXT: %{{.+}} = shl i64 %[[dsh]], 32
; CHECK: invertjoin:
; CHECK: %[[dhishl:.+]] = and i64 %[[dpack:.+]], -4294967296
; CHECK-NEXT: %{{.+}} = and i64 %[[dpack]], 4294967295
; CHECK: store i64 0, i64* %"lo.ext'de"
; CHECK-NEXT: %[[dhs:.+]] = load i64, i64* %"hi.shl'de"
; CHECK-NEXT: %{{.+}} = lshr i64 %[[dhs]], 32
