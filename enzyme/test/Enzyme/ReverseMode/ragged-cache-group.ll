; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %OPloadEnzyme -enzyme-preopt=false -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s
; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-group-packed-caches=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s --check-prefix=APART

; Two values per row are cached, and the row count depends on the event. In a
; combined derivative both caches share one offset table and one growing
; buffer of two-value records, so the nest allocates once per growth rather
; than once per growth and cache.

declare void @__enzyme_autodiff(...)

define double @ragged2(ptr noalias %x, ptr noalias %y, ptr noalias readonly %lengths, i64 %n) {
entry:
  %has.events = icmp sgt i64 %n, 0
  br i1 %has.events, label %event, label %exit
event:
  %i = phi i64 [0, %entry], [%inext, %event.end]
  %s0 = phi double [0.0, %entry], [%s2, %event.end]
  %lenptr = getelementptr i64, ptr %lengths, i64 %i
  %len = load i64, ptr %lenptr
  %has.rows = icmp sgt i64 %len, 0
  br i1 %has.rows, label %row, label %event.end
row:
  %j = phi i64 [0, %event], [%jnext, %row]
  %s = phi double [%s0, %event], [%snext, %row]
  %p = getelementptr double, ptr %x, i64 %j
  %q = getelementptr double, ptr %y, i64 %j
  %v = load double, ptr %p
  %w = load double, ptr %q
  %vw = fmul double %v, %w
  store double %vw, ptr %p
  store double %vw, ptr %q
  %snext = fadd double %s, %vw
  %jnext = add nuw nsw i64 %j, 1
  %row.done = icmp eq i64 %jnext, %len
  br i1 %row.done, label %event.end, label %row
event.end:
  %s2 = phi double [%s0, %event], [%snext, %row]
  %inext = add nuw nsw i64 %i, 1
  %event.done = icmp eq i64 %inext, %n
  br i1 %event.done, label %exit, label %event
exit:
  %result = phi double [0.0, %entry], [%s2, %event.end]
  ret double %result
}

define void @test(ptr %x, ptr %dx, ptr %y, ptr %dy, ptr %lengths, i64 %n) {
  call void (...) @__enzyme_autodiff(ptr @ragged2, metadata !"enzyme_dup", ptr %x, ptr %dx, metadata !"enzyme_dup", ptr %y, ptr %dy, metadata !"enzyme_const", ptr %lengths, i64 %n)
  ret void
}

; One offset table for the nest, and one growth per event for both caches.
; CHECK-LABEL: define internal void @differagged2(
; CHECK: event.preheader:
; CHECK: %[[TABLE:.+]] = tail call noalias nonnull ptr @malloc(i64 %mallocsize)
; CHECK-NEXT: store ptr null, ptr %[[TABLE]], align 8
; CHECK-NEXT: br label %event
; CHECK: row.preheader:
; CHECK-NOT: @malloc
; A record holds two doubles: 16 bytes.
; CHECK: mul nuw i64 %{{.+}}, 16
; CHECK-NEXT: %[[BYTES:.+]] = mul nuw i64 %{{.+}}, 16
; CHECK: grow.i:
; CHECK-NEXT: call noalias nonnull ptr @malloc(i64 %[[BYTES]])
; CHECK-NOT: @malloc
; CHECK: row:
; w is slot 0 and v slot 1 of each record.
; CHECK: %[[RV:.+]] = mul nuw i64 %{{.+}}, 2
; CHECK-NEXT: %[[SV:.+]] = add nuw i64 %[[RV]], 1
; CHECK-NEXT: %[[PV:.+]] = getelementptr inbounds double, ptr %{{.+}}, i64 %[[SV]]
; CHECK-NEXT: store double %v, ptr %[[PV]]
; CHECK: %[[RW:.+]] = mul nuw i64 %{{.+}}, 2
; CHECK-NEXT: %[[PW:.+]] = getelementptr inbounds double, ptr %{{.+}}, i64 %[[RW]]
; CHECK-NEXT: store double %w, ptr %[[PW]]
; CHECK-NOT: @malloc
; The buffer and the table are released once.
; CHECK: invertevent.preheader:
; CHECK-NEXT: %[[BUF:.+]] = load ptr, ptr %[[ROOT:.+]], align 8
; CHECK-NEXT: tail call void @free(ptr %[[BUF]])
; CHECK-NEXT: tail call void @free(ptr nonnull %[[ROOT]])
; CHECK-NEXT: br label %invertentry

; Without grouping, each cache has its own table and its own growth.
; APART-LABEL: define internal void @differagged2(
; APART: event.preheader:
; APART: tail call noalias nonnull ptr @malloc(i64 %mallocsize)
; APART: tail call noalias nonnull ptr @malloc(i64 %mallocsize{{[0-9]+}})
; APART: grow.i:
; APART-NEXT: call noalias nonnull ptr @malloc(
; APART: grow.i{{[0-9]+}}:
; APART-NEXT: call noalias nonnull ptr @malloc(
; APART: invertevent.preheader:
; APART-COUNT-4: tail call void @free(
