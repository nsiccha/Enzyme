; RUN: if [ %llvmver -ge 11 ] && [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme -S | FileCheck %s; fi
; RUN: if [ %llvmver -ge 11 ]; then %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme" -S | FileCheck %s ; fi

; A call that the reverse pass runs combined with its forward pass. The primal
; return value must reach the caller on every path: on one that skips the call,
; and on whichever of several returns the forward pass took.

source_filename = "combinedcondret.ll"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128-ni:10:11:12:13"
target triple = "x86_64-linux-gnu"

declare { double, double } @__enzyme_autodiff(...)

; Function Attrs: noinline
define internal fastcc void @square(double* nocapture nofree noundef nonnull %p) #0 {
entry:
  %v = load double, double* %p, align 8
  %sq = fmul double %v, %v
  store double %sq, double* %p, align 8
  ret void
}

; The returned value does not depend on the call.
define double @cond_indep(double %x, double* %p, i1 %c) {
entry:
  %v = fmul double %x, 3.000000e+00
  br i1 %c, label %docall, label %exit

docall:
  call fastcc void @square(double* nocapture nofree noundef nonnull %p)
  br label %exit

exit:
  ret double %v
}

; The returned value reads memory the call may write, from a block the call
; does not dominate.
define double @cond_dep(double %x, double* %p, i64* %q, i1 %c) {
entry:
  %v = fmul double %x, 3.000000e+00
  br i1 %c, label %docall, label %exit

docall:
  call fastcc void @square(double* nocapture nofree noundef nonnull %p)
  br label %exit

exit:
  %n = load i64, i64* %q, align 8
  %nf = sitofp i64 %n to double
  %r = fadd double %v, %nf
  ret double %r
}

; Two returns after the call, one of them reading memory the call may write.
define double @two_returns(double %x, double* %p, i64* %q, i1 %c) {
entry:
  call fastcc void @square(double* nocapture nofree noundef nonnull %p)
  %n = load i64, i64* %q, align 8
  %nf = sitofp i64 %n to double
  br i1 %c, label %first, label %second

first:
  ret double %nf

second:
  %y = fmul double %x, 2.000000e+00
  ret double %y
}

define { double, double } @wrap_indep(double %x, double* %p, double* %dp, i1 %c) {
entry:
  %res = call { double, double } (...) @__enzyme_autodiff(double (double, double*, i1)* @cond_indep, metadata !"enzyme_primal_return", double %x, metadata !"enzyme_dup", double* %p, double* %dp, metadata !"enzyme_const", i1 %c)
  ret { double, double } %res
}

define { double, double } @wrap_dep(double %x, double* %p, double* %dp, i64* %q, i1 %c) {
entry:
  %res = call { double, double } (...) @__enzyme_autodiff(double (double, double*, i64*, i1)* @cond_dep, metadata !"enzyme_primal_return", double %x, metadata !"enzyme_dup", double* %p, double* %dp, metadata !"enzyme_const", i64* %q, metadata !"enzyme_const", i1 %c)
  ret { double, double } %res
}

define { double, double } @wrap_two_returns(double %x, double* %p, double* %dp, i64* %q, i1 %c) {
entry:
  %res = call { double, double } (...) @__enzyme_autodiff(double (double, double*, i64*, i1)* @two_returns, metadata !"enzyme_primal_return", double %x, metadata !"enzyme_dup", double* %p, double* %dp, metadata !"enzyme_const", i64* %q, metadata !"enzyme_const", i1 %c)
  ret { double, double } %res
}

attributes #0 = { argmemonly noinline nounwind }

; The call still runs combined, and the forward pass stores the return value
; before it branches to the reverse pass.

; CHECK: define internal { double, double } @diffecond_indep(double %x, double* nocapture %p, double* nocapture %"p'", i1 %c, double %differeturn)
; CHECK: {{^}}exit:
; CHECK-NEXT:   store double %v, double* %toreturn, align 8
; CHECK-NEXT:   br label %invertexit
; CHECK: {{^}}invertdocall:
; CHECK-NEXT:   call fastcc void @diffesquare(double* nocapture nofree %p, double* nocapture nofree %"p'")
; CHECK-NEXT:   br label %invertentry

; The call is not combined: the forward pass runs it augmented, so the load and
; the store of the return value stay on the path that skips it.

; CHECK: define internal { double, double } @diffecond_dep(double %x, double* nocapture %p, double* nocapture %"p'", i64* nocapture readonly %q, i1 %c, double %differeturn)
; CHECK: {{^}}docall:
; CHECK-NEXT:   %_augmented = call {{(fast )?}}fastcc double @augmented_square(double* nocapture nofree %p, double* nocapture nofree %"p'")
; CHECK: {{^}}exit:
; CHECK-NEXT:   %n = load i64, i64* %q, align 8
; CHECK-NEXT:   %nf = sitofp i64 %n to double
; CHECK-NEXT:   %r = fadd double %v, %nf
; CHECK-NEXT:   store double %r, double* %toreturn, align 8
; CHECK-NEXT:   br label %invertexit

; The call is not combined: a moved store of one return value would overwrite
; the other's on the path that took the other return.

; CHECK: define internal { double, double } @diffetwo_returns(double %x, double* nocapture %p, double* nocapture %"p'", i64* nocapture readonly %q, i1 %c, double %differeturn)
; CHECK: %_augmented = call {{(fast )?}}fastcc double @augmented_square(double* nocapture nofree %p, double* nocapture nofree %"p'")
; CHECK: {{^}}first:
; CHECK-NEXT:   store double %nf, double* %toreturn, align 8
; CHECK-NEXT:   br label %invertfirst
; CHECK: {{^}}second:
; CHECK-NEXT:   %y = fmul double %x, 2.000000e+00
; CHECK-NEXT:   store double %y, double* %toreturn, align 8
; CHECK-NEXT:   br label %invertsecond
