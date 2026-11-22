; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="print-type-analysis" -type-analysis-func=copy_pair -S -o /dev/null | FileCheck %s; fi
;
; A pair of floats (a ComplexF32) copied as one i64, as SROA emits it: one
; path unpacks the upper float with lshr 32, another computes it as a float,
; and the merged halves are packed again with zext, shl 32 and a disjoint or.
; Shifting by a whole float moves floats between lanes and fills the vacated
; lane with zero bits, as zext does, so the shifted values stay floats.
declare void @use_pair(ptr "enzyme_type"="{[-1]:Pointer, [-1,0]:Float@float, [-1,4]:Float@float}")

define void @copy_pair(ptr %src, ptr %dst, i1 %c, i1 %d) {
entry:
  call void @use_pair(ptr %src)
  br i1 %c, label %copy, label %other
copy:
  %ld = load i64, ptr %src, align 4
  %lo.c = trunc i64 %ld to i32
  %hi.sh = lshr i64 %ld, 32
  %hi.c = trunc i64 %hi.sh to i32
  br label %join
other:
  %re = load float, ptr %src, align 4
  %ip = getelementptr inbounds float, ptr %src, i64 1
  %im = load float, ptr %ip, align 4
  %nim = fneg float %im
  %lo.n = bitcast float %re to i32
  %hi.n = bitcast float %nim to i32
  br i1 %d, label %join, label %diag
diag:
  br label %join
join:
  %hi = phi i32 [ %hi.c, %copy ], [ %hi.n, %other ], [ 0, %diag ]
  %lo = phi i32 [ %lo.c, %copy ], [ %lo.n, %other ], [ %lo.n, %diag ]
  %hi.ext = zext i32 %hi to i64
  %hi.shl = shl nuw i64 %hi.ext, 32
  %lo.ext = zext i32 %lo to i64
  %pack = or i64 %hi.shl, %lo.ext
  store i64 %pack, ptr %dst, align 4
  ret void
}

; CHECK: %ld = load i64, ptr %src, align 4: {[-1]:Float@float}
; CHECK: %hi.sh = lshr i64 %ld, 32: {[-1]:Float@float}
; CHECK: %hi.c = trunc i64 %hi.sh to i32: {[-1]:Float@float}
; CHECK: %hi = phi i32 {{.*}}: {[-1]:Float@float}
; CHECK: %hi.ext = zext i32 %hi to i64: {[-1]:Float@float}
; CHECK: %hi.shl = shl nuw i64 %hi.ext, 32: {[-1]:Float@float}
; CHECK: %pack = or i64 %hi.shl, %lo.ext: {[-1]:Float@float}
