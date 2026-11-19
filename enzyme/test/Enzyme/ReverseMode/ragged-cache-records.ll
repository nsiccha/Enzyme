; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-smallbool -enzyme-print-perf -passes="enzyme,verify" -S 2>&1 | FileCheck %s
; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-smallbool -passes="enzyme,verify" -S | %lli -
; RUN: %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-smallbool -enzyme-group-packed-caches=false -passes="enzyme,verify" -S | %lli -
;
; Both the mixed record and the predicate are overwritten. In a ragged
; buffer each predicate gets a whole byte, even with enzyme-smallbool.
; CHECK-DAG: Ragged cache record: { double, i64 }, 2 chunks, packed
; CHECK-DAG: Ragged cache flag: i1, 2 chunks, packed

@lengths = constant [3 x i64] [i64 1, i64 3, i64 2]
@record = global { double, i64 } { double 1.0, i64 1 }
@shadow = global { double, i64 } zeroinitializer
@flag = global i1 true

declare void @__enzyme_autodiff(...)

define double @walk(ptr noalias %state, ptr noalias %switch, ptr noalias readonly %lengths) {
entry:
  br label %event
event:
  %i = phi i64 [0, %entry], [%nexti, %end]
  %total = phi double [0.0, %entry], [%sum, %end]
  %p = getelementptr i64, ptr %lengths, i64 %i
  %count = load i64, ptr %p
  br label %row
row:
  %j = phi i64 [0, %event], [%nextj, %row]
  %acc = phi double [%total, %event], [%sum, %row]
  %record = load { double, i64 }, ptr %state, !enzyme_mustcache !0
  %value = extractvalue { double, i64 } %record, 0
  %tag = extractvalue { double, i64 } %record, 1
  %flag = load i1, ptr %switch, !enzyme_mustcache !0
  %flip = xor i1 %flag, true
  store i1 %flip, ptr %switch
  %tagged = icmp eq i64 %tag, 1
  %factor = select i1 %tagged, double %value, double 1.0
  %square = fmul double %value, %factor
  %next = select i1 %flag, double %square, double %value
  %updated = insertvalue { double, i64 } %record, double %next, 0
  store { double, i64 } %updated, ptr %state
  %sum = fadd double %acc, %next
  %nextj = add nuw i64 %j, 1
  %last = icmp eq i64 %nextj, %count
  br i1 %last, label %end, label %row
end:
  %nexti = add nuw i64 %i, 1
  %done = icmp eq i64 %nexti, 3
  br i1 %done, label %exit, label %event
exit:
  ret double %sum
}

; At 1, alternating square and identity gives 2 + 2 + 4 + 4 + 8 + 8.
define i32 @main() {
  call void (...) @__enzyme_autodiff(ptr @walk, metadata !"enzyme_dup", ptr @record, ptr @shadow,
      metadata !"enzyme_const", ptr @flag, metadata !"enzyme_const", ptr @lengths)
  %deriv = load double, ptr @shadow
  %wrong = fcmp une double %deriv, 28.0
  %status = zext i1 %wrong to i32
  ret i32 %status
}

!0 = !{}
