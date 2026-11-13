; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %OPloadEnzyme -enzyme-preopt=false -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s
; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s --check-prefix=FLOAT32
; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-zero-cache=true -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s --check-prefix=ZERO

; The row count depends on the event, but not on the component. Keep all rows
; in a geometrically growing buffer, with an offset saved for every event.
; Each component overwrites x, so sharing values would give the wrong gradient.

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

; A second element type in the same module must use its own typed grower.
define float @ragged_float(ptr noalias %x, ptr noalias readonly %lengths, i64 %n, i64 %components) {
entry:
  %has.events = icmp sgt i64 %n, 0
  br i1 %has.events, label %event, label %exit
event:
  %i = phi i64 [0, %entry], [%inext, %event.end]
  %s0 = phi float [0.0, %entry], [%s3, %event.end]
  %lenptr = getelementptr i64, ptr %lengths, i64 %i
  %len = load i64, ptr %lenptr
  %has.components = icmp sgt i64 %components, 0
  br i1 %has.components, label %component, label %event.end
component:
  %k = phi i64 [0, %event], [%knext, %component.end]
  %s1 = phi float [%s0, %event], [%s2, %component.end]
  %has.rows = icmp sgt i64 %len, 0
  br i1 %has.rows, label %row, label %component.end
row:
  %j = phi i64 [0, %component], [%jnext, %row]
  %s = phi float [%s1, %component], [%snext, %row]
  %p = getelementptr float, ptr %x, i64 %j
  %v = load float, ptr %p
  %sq = fmul float %v, %v
  store float %sq, ptr %p
  %snext = fadd float %s, %sq
  %jnext = add nuw nsw i64 %j, 1
  %row.done = icmp eq i64 %jnext, %len
  br i1 %row.done, label %component.end, label %row
component.end:
  %s2 = phi float [%s1, %component], [%snext, %row]
  %knext = add nuw nsw i64 %k, 1
  %component.done = icmp eq i64 %knext, %components
  br i1 %component.done, label %event.end, label %component
event.end:
  %s3 = phi float [%s0, %event], [%s2, %component.end]
  %inext = add nuw nsw i64 %i, 1
  %event.done = icmp eq i64 %inext, %n
  br i1 %event.done, label %exit, label %event
exit:
  %result = phi float [0.0, %entry], [%s3, %event.end]
  ret float %result
}

define void @test_float(ptr %x, ptr %dx, ptr %lengths, i64 %n, i64 %components) {
  call void (...) @__enzyme_autodiff(ptr @ragged_float, metadata !"enzyme_dup", ptr %x, ptr %dx, metadata !"enzyme_const", ptr %lengths, i64 %n, i64 %components)
  ret void
}

; CHECK-LABEL: define internal void @differagged(
; CHECK: event.preheader:
; CHECK: %[[TABLECOUNT:.+]] = add i64 %n, 1
; CHECK: mul nuw nsw i64 %[[TABLECOUNT]], 8
; CHECK: %[[OUTER:[a-zA-Z_0-9]+]] = {{.*}}@malloc
; CHECK-NEXT: store ptr null, ptr %[[OUTER]]
; CHECK: event:
; CHECK: component.preheader:
; CHECK: %[[CLAMP:.+]] = select i1 {{.+}}, i64 0, i64 %len
; CHECK-NEXT: %[[COUNT:.+]] = mul nuw nsw i64 %[[CLAMP]], {{.+}}
; CHECK: add nuw i64 {{.+}}, %[[COUNT]]
; CHECK: shl i64 {{.+}}, 1
; CHECK-NOT: @malloc
; CHECK: br i1 {{.+}}, label %grow.i,
; CHECK: grow.i:
; CHECK: %[[GROWN:[a-zA-Z_0-9]+]] = {{.*}}@malloc
; CHECK: call void @llvm.memcpy{{.*}}, !enzyme_truetype ![[FLOAT:[0-9]+]]
; CHECK: call void @free(ptr
; CHECK: __enzyme_grow_ragged_cache_double.exit:
; CHECK: store ptr {{.+}}, ptr %[[OUTER]]
; CHECK: %[[OFFSET:.+]] = inttoptr i64 {{.+}} to ptr
; CHECK-NEXT: store ptr %[[OFFSET]], ptr
; CHECK: component:
; CHECK-NOT: @malloc
; CHECK: row:
; CHECK-NOT: @malloc
; CHECK: ptrtoint ptr {{.+}} to i64
; CHECK: store double %v,
; CHECK-NOT: @malloc
; CHECK: invertevent.preheader:
; An all-empty nest has a null value buffer. Its free must allow null.
; CHECK: call void @free(ptr %
; CHECK: call void @free(ptr nonnull %
; CHECK: invertrow:
; CHECK: ptrtoint ptr {{.+}} to i64
; CHECK: getelementptr inbounds double
; CHECK: ![[FLOAT]] = !{!"Float@double", i64 0}

; ZERO-LABEL: define internal void @differagged(
; ZERO: grow.i:
; ZERO: call void @llvm.memcpy{{.*}}, !enzyme_truetype ![[FLOAT:[0-9]+]]
; ZERO: call void @llvm.memset{{.*}}, !enzyme_truetype ![[FLOAT]]
; ZERO: ![[FLOAT]] = !{!"Float@double", i64 0}

; FLOAT32-LABEL: define internal void @differagged_float(
; FLOAT32: call void @llvm.memcpy{{.*}}, !enzyme_truetype ![[FLOAT:[0-9]+]]
; FLOAT32: __enzyme_grow_ragged_cache_float.exit:
; FLOAT32: store float %v,
; FLOAT32: ![[FLOAT]] = !{!"Float@float", i64 0}
