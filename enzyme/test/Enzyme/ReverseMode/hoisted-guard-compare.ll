; RUN: %opt %defaultLoadEnzyme -enzyme-preopt=false -passes="enzyme,verify" -S %s -o %t
; RUN: %lli %t

; %a is infinite when %lo is. Its square feeds the result only in %use, which
; a run with %take false skips; the width %w is also computed before the
; branch, but only a comparison reads it, so it carries no derivative and must
; not keep the zero adjoint of %a from being protected.
declare double @__enzyme_autodiff(i8*, ...)
declare double @llvm.exp.f64(double)

define double @compared_width(double %x, double %lo, i1 %take) {
entry:
  %a = fmul double %x, %lo
  %w = fsub double 1.0, %a
  %sq = fmul double %a, %a
  br i1 %take, label %check, label %skip
check:
  %wide = fcmp oge double %w, 1.25e-1
  br i1 %wide, label %use, label %skip
use:
  %neg = fneg double %sq
  %e = call double @llvm.exp.f64(double %neg)
  br label %skip
skip:
  %r = phi double [ %x, %entry ], [ 0.0, %check ], [ %e, %use ]
  ret double %r
}

; The square is computed in a later block that every run reaches, and it is
; protected because its only use is skipped. That protection passes on to %a.
define double @protected_user_later(double %x, double %lo, i1 %take) {
entry:
  %a = fmul double %x, %lo
  br label %next
next:
  %sq = fmul double %a, %a
  br i1 %take, label %use, label %skip
use:
  %neg = fneg double %sq
  %e = call double @llvm.exp.f64(double %neg)
  br label %skip
skip:
  %r = phi double [ %x, %next ], [ %e, %use ]
  ret double %r
}

; Control: %a is also compared, but a derivative-carrying use of it runs on
; every path, so an ordinary zero adjoint still follows IEEE arithmetic.
define double @compared_and_used(double %x, double %lo, i1 %take) {
entry:
  %a = fmul double %x, %lo
  %w = fsub double 1.0, %a
  %wide = fcmp oge double %w, 1.25e-1
  %c = and i1 %take, %wide
  br i1 %c, label %use, label %skip
use:
  %z = fmul double %a, 0.0
  ret double %z
skip:
  ret double %a
}

define i32 @main() {
  %width = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, double, i1)* @compared_width to i8*), double 1.0, metadata !"enzyme_const", double 0xFFF0000000000000, i1 false)
  %later = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, double, i1)* @protected_user_later to i8*), double 1.0, metadata !"enzyme_const", double 0xFFF0000000000000, i1 false)
  %used = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, double, i1)* @compared_and_used to i8*), double 1.0, metadata !"enzyme_const", double 0xFFF0000000000000, i1 true)
  %finite = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double, double, i1)* @compared_width to i8*), double 2.0e-1, metadata !"enzyme_const", double 1.0, i1 true)
  %a = fcmp oeq double %width, 1.0
  %b = fcmp oeq double %later, 1.0
  %c = fcmp uno double %used, %used
  ; d/dx exp(-x^2) at 0.2 is -0.4 * exp(-0.04)
  %e = fadd double %finite, 0x3FD898A131F33C71
  %ea = call double @llvm.fabs.f64(double %e)
  %d = fcmp olt double %ea, 1.0e-12
  %ab = and i1 %a, %b
  %abc = and i1 %ab, %c
  %ok = and i1 %abc, %d
  %rc = select i1 %ok, i32 0, i32 1
  ret i32 %rc
}

declare double @llvm.fabs.f64(double)
