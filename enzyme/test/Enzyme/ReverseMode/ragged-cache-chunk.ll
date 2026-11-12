; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %OPloadEnzyme -enzyme-preopt=false -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s

; The row count depends on the event, but not on the component. Allocate one
; contiguous cache for every component of an event. Each component overwrites
; x, so sharing the values themselves would give the wrong derivative.

declare void @__enzyme_autodiff(...)

define double @ragged(ptr noalias %x, ptr noalias readonly %lengths, i64 %n, i64 %components) {
entry:
  %has.events = icmp sgt i64 %n, 0
  br i1 %has.events, label %event, label %exit
event:
  %i = phi i64 [0, %entry], [%inext, %event.end]
  %s0 = phi double [0.0, %entry], [%s3, %event.end]
  %lenptr = getelementptr i64, ptr %lengths, i64 %i
  %len = load i64, ptr %lenptr
  %has.components = icmp sgt i64 %components, 0
  br i1 %has.components, label %component, label %event.end
component:
  %k = phi i64 [0, %event], [%knext, %component.end]
  %s1 = phi double [%s0, %event], [%s2, %component.end]
  %has.rows = icmp sgt i64 %len, 0
  br i1 %has.rows, label %row, label %component.end
row:
  %j = phi i64 [0, %component], [%jnext, %row]
  %s = phi double [%s1, %component], [%snext, %row]
  %p = getelementptr double, ptr %x, i64 %j
  %v = load double, ptr %p
  %sq = fmul double %v, %v
  store double %sq, ptr %p
  %snext = fadd double %s, %sq
  %jnext = add nuw nsw i64 %j, 1
  %row.done = icmp eq i64 %jnext, %len
  br i1 %row.done, label %component.end, label %row
component.end:
  %s2 = phi double [%s1, %component], [%snext, %row]
  %knext = add nuw nsw i64 %k, 1
  %component.done = icmp eq i64 %knext, %components
  br i1 %component.done, label %event.end, label %component
event.end:
  %s3 = phi double [%s0, %event], [%s2, %component.end]
  %inext = add nuw nsw i64 %i, 1
  %event.done = icmp eq i64 %inext, %n
  br i1 %event.done, label %exit, label %event
exit:
  %result = phi double [0.0, %entry], [%s3, %event.end]
  ret double %result
}

define void @test(ptr %x, ptr %dx, ptr %lengths, i64 %n, i64 %components) {
  call void (...) @__enzyme_autodiff(ptr @ragged, metadata !"enzyme_dup", ptr %x, ptr %dx, metadata !"enzyme_const", ptr %lengths, i64 %n, i64 %components)
  ret void
}

; CHECK-LABEL: define internal void @differagged(
; CHECK: event.preheader:
; CHECK: mul nuw nsw i64 %n, 8
; CHECK: %[[OUTER:[a-zA-Z_0-9]+]] = {{.*}}@malloc
; CHECK: event:
; CHECK: component.preheader:
; CHECK: %[[CLAMP:.+]] = select i1 {{.+}}, i64 0, i64 %len
; CHECK-NEXT: %[[COUNT:.+]] = mul nuw nsw i64 %[[CLAMP]], {{.+}}
; CHECK: %[[INNER:[a-zA-Z_0-9]+]] = {{.*}}@malloc
; CHECK: component:
; CHECK-NOT: @malloc
; CHECK: row:
; CHECK-NOT: @malloc
; CHECK: store double %v,
; CHECK-NOT: @malloc
; CHECK: invertevent:
