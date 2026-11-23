; RUN: if [ %llvmver -ge 11 ] && [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme -S | FileCheck %s; fi
; RUN: if [ %llvmver -ge 11 ]; then %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme" -S | FileCheck %s ; fi

; Two calls that the reverse pass could each run combined with their forward
; pass, both feeding one returned sum. Combining a call moves the instructions
; that use its result after it, into its reverse block. A sum that uses both
; results can follow only one of the two calls.

source_filename = "combinedmovedusers.ll"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128-ni:10:11:12:13"
target triple = "x86_64-linux-gnu"

declare { double, double, double } @__enzyme_autodiff(...)

; Function Attrs: noinline
define internal fastcc double @sq(double %x) #0 {
entry:
  %r = fmul double %x, %x
  ret double %r
}

; The calls are in different blocks. The reverse pass reaches the second one
; first, so the sum cannot follow the first.
define double @two_blocks(double %x, double %y) {
entry:
  %a = call fastcc double @sq(double %x)
  %sa = fmul double %a, 3.000000e+00
  br label %next

next:
  %b = call fastcc double @sq(double %y)
  %sb = fmul double %b, 5.000000e+00
  %s = fadd double %sa, %sb
  ret double %s
}

; The calls are in one block, whose reverse code runs the second call's reverse
; before the first's, so the sum follows the first call.
define double @one_block(double %x, double %y) {
entry:
  %a = call fastcc double @sq(double %x)
  %sa = fmul double %a, 3.000000e+00
  %b = call fastcc double @sq(double %y)
  %sb = fmul double %b, 5.000000e+00
  %s = fadd double %sa, %sb
  ret double %s
}

define { double, double, double } @wrap_two_blocks(double %x, double %y) {
entry:
  %res = call { double, double, double } (...) @__enzyme_autodiff(double (double, double)* @two_blocks, metadata !"enzyme_primal_return", double %x, double %y)
  ret { double, double, double } %res
}

define { double, double, double } @wrap_one_block(double %x, double %y) {
entry:
  %res = call { double, double, double } (...) @__enzyme_autodiff(double (double, double)* @one_block, metadata !"enzyme_primal_return", double %x, double %y)
  ret { double, double, double } %res
}

attributes #0 = { noinline nounwind readnone }

; The first call runs combined and the sum follows it. The second call is not
; combined: the forward pass computes its result, so the sum reads it there.

; CHECK: define internal { double, double, double } @diffetwo_blocks(double %x, double %y, double %differeturn)
; CHECK: {{^}}next:
; CHECK-NEXT:   %b = call fastcc double @sq(double %y)
; CHECK-NEXT:   %sb = fmul double %b, 5.000000e+00
; CHECK-NEXT:   br label %invertnext
; CHECK: {{^}}invertentry:
; CHECK:   %[[ra:.+]] = call fastcc { double, double } @diffesq(double %x, double
; CHECK:   %[[a:.+]] = extractvalue { double, double } %[[ra]], 0
; CHECK-NEXT:   %sa = fmul double %[[a]], 3.000000e+00
; CHECK-NEXT:   %s = fadd double %sa, %sb
; CHECK-NEXT:   store double %s, {{.*}}%toreturn
; CHECK: {{^}}invertnext:
; CHECK:   call fastcc { double } @diffesq{{.*}}(double %y, double
; CHECK: br label %invertentry

; Both calls run combined, and the sum follows the first.

; CHECK: define internal { double, double, double } @diffeone_block(double %x, double %y, double %differeturn)
; CHECK-NOT: call fastcc double @sq(
; CHECK:   %[[rb:.+]] = call fastcc { double, double } @diffesq(double %y, double
; CHECK:   %[[b:.+]] = extractvalue { double, double } %[[rb]], 0
; CHECK-NEXT:   %sb = fmul double %[[b]], 5.000000e+00
; CHECK:   %[[ra:.+]] = call fastcc { double, double } @diffesq(double %x, double
; CHECK:   %[[a:.+]] = extractvalue { double, double } %[[ra]], 0
; CHECK-NEXT:   %sa = fmul double %[[a]], 3.000000e+00
; CHECK-NEXT:   %s = fadd double %sa, %sb
; CHECK-NEXT:   store double %s, {{.*}}%toreturn
