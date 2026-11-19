; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-print-perf -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S 2>&1 | FileCheck %s
; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -passes="enzyme,verify" -S | %lli -
; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-group-packed-caches=false -passes="enzyme,verify" -S | %lli -
;
; Variable-length blocks inside variable-length groups. Each overwritten
; vector must survive both levels of growth. All three buffers are released
; at the end of the outermost loop.
; CHECK: Ragged cache v: <2 x double>, 3 chunks, packed
; CHECK-LABEL: define internal void @diffenested(
; CHECK: store <2 x double> %v
; CHECK: invertevent.preheader:
; CHECK: @free(
; CHECK: @free(
; CHECK: @free(

declare void @__enzyme_autodiff(...)

define double @nested(ptr noalias %x, ptr noalias readonly %lengths, i64 %n) {
entry:
  %has.events = icmp sgt i64 %n, 0
  br i1 %has.events, label %event, label %exit
event:
  %i = phi i64 [0, %entry], [%inext, %event.end]
  %s0 = phi double [0.0, %entry], [%s3, %event.end]
  %level = getelementptr ptr, ptr %lengths, i64 %i
  %bounds = load ptr, ptr %level
  %components = load i64, ptr %bounds
  %has.components = icmp sgt i64 %components, 0
  br i1 %has.components, label %component, label %event.end
component:
  %k = phi i64 [0, %event], [%knext, %component.end]
  %s1 = phi double [%s0, %event], [%s2, %component.end]
  %k1 = add nuw i64 %k, 1
  %lenptr = getelementptr i64, ptr %bounds, i64 %k1
  %len = load i64, ptr %lenptr
  %has.rows = icmp sgt i64 %len, 0
  br i1 %has.rows, label %row, label %component.end
row:
  %j = phi i64 [0, %component], [%jnext, %row]
  %s = phi double [%s1, %component], [%snext, %row]
  %p = getelementptr <2 x double>, ptr %x, i64 %j
  %v = load <2 x double>, ptr %p, align 8
  %sq = fmul <2 x double> %v, %v
  store <2 x double> %sq, ptr %p, align 8
  %first = extractelement <2 x double> %sq, i32 0
  %snext = fadd double %s, %first
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

define void @test(ptr %x, ptr %dx, ptr %lengths, i64 %n) {
  call void (...) @__enzyme_autodiff(ptr @nested, metadata !"enzyme_dup", ptr %x, ptr %dx, metadata !"enzyme_const", ptr %lengths, i64 %n)
  ret void
}


@empty = constant [1 x i64] [i64 0]
@group1 = constant [4 x i64] [i64 3, i64 1, i64 0, i64 5]
@group2 = constant [2 x i64] [i64 1, i64 2]
@bounds = constant [4 x ptr] [ptr @empty, ptr @group1, ptr @empty, ptr @group2]
@x = global [5 x <2 x double>] [
  <2 x double> <double 1.0, double 1.0>, <2 x double> <double 1.0, double 1.0>,
  <2 x double> <double 1.0, double 1.0>, <2 x double> <double 1.0, double 1.0>,
  <2 x double> <double 1.0, double 1.0>]
@dx = global [5 x <2 x double>] zeroinitializer

; A lane squared k times contributes 2 + 4 + ... + 2^k to the sum's
; derivative at 1. The unused lane has zero adjoint everywhere.
define i32 @main() {
  call void @test(ptr @x, ptr @dx, ptr @bounds, i64 4)
  %p1 = getelementptr <2 x double>, ptr @dx, i64 1
  %p2 = getelementptr <2 x double>, ptr @dx, i64 2
  %p3 = getelementptr <2 x double>, ptr @dx, i64 3
  %p4 = getelementptr <2 x double>, ptr @dx, i64 4
  %d0 = load <2 x double>, ptr @dx
  %d1 = load <2 x double>, ptr %p1
  %d2 = load <2 x double>, ptr %p2
  %d3 = load <2 x double>, ptr %p3
  %d4 = load <2 x double>, ptr %p4
  %ok0 = fcmp oeq <2 x double> %d0, <double 14.0, double 0.0>
  %ok1 = fcmp oeq <2 x double> %d1, <double 6.0, double 0.0>
  %ok2 = fcmp oeq <2 x double> %d2, <double 2.0, double 0.0>
  %ok3 = fcmp oeq <2 x double> %d3, <double 2.0, double 0.0>
  %ok4 = fcmp oeq <2 x double> %d4, <double 2.0, double 0.0>
  %both = and <2 x i1> %ok0, %ok1
  %three = and <2 x i1> %both, %ok2
  %four = and <2 x i1> %three, %ok3
  %all = and <2 x i1> %four, %ok4
  %mask = bitcast <2 x i1> %all to i2
  %wrong = icmp ne i2 %mask, -1
  %status = zext i1 %wrong to i32
  ret i32 %status
}
