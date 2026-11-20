; RUN: %opt %defaultLoadEnzyme -enzyme-preopt=false -passes="enzyme,verify" -S %s -o %t
; RUN: %lli %t

; The multiply is available before the branch, but only one branch uses it.
; Its zero adjoint when the branch is skipped must not multiply an infinite x.
declare double @__enzyme_autodiff(i8*, ...)
declare double @llvm.sin.f64(double)

define double @guarded(double %x, i1 %take) {
entry:
  %square = fmul double %x, %x
  br i1 %take, label %use, label %skip
use:
  %v = call double @llvm.sin.f64(double %square)
  ret double %v
skip:
  ret double %x
}

; Each use is conditional individually. Together they read the square on
; every path, so an ordinary zero seed still follows IEEE arithmetic.
define double @always_used(double %x, i1 %take) {
entry:
  %square = fmul double %x, %x
  br i1 %take, label %left, label %right
left:
  %zero = fmul double %square, 0.0
  ret double %zero
right:
  ret double %square
}

define i32 @main() {
  %bypass = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i1)* @guarded to i8*), double 0x7FF0000000000000, i1 false)
  %taken = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i1)* @guarded to i8*), double 0.0, i1 true)
  %used = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, i1)* @always_used to i8*), double 0x7FF0000000000000, i1 true)
  %a = fcmp oeq double %bypass, 1.0
  %b = fcmp oeq double %taken, 0.0
  %c = fcmp uno double %used, %used
  %ab = and i1 %a, %b
  %ok = and i1 %ab, %c
  %rc = select i1 %ok, i32 0, i32 1
  ret i32 %rc
}
