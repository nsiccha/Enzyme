; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -print-type-analysis -type-analysis-func=caller -o /dev/null | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -passes="print-type-analysis" -type-analysis-func=caller -S -o /dev/null | FileCheck %s

; Explicit frontend type layouts must survive merging into the analysis even
; when their fields extend past the default 500-byte inference limit.
declare void @callee(i8* "enzyme_type"="{[-1]:Pointer, [-1,0]:Float@double, [-1,512]:Float@double, [-1,528]:Float@double}")

define void @caller(i8* %x) {
entry:
  call void @callee(i8* %x)
  ret void
}

; CHECK: i8* %x: {[-1]:Pointer, [-1,0]:Float@double, [-1,512]:Float@double, [-1,528]:Float@double}
