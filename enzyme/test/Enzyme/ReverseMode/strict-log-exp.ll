; RUN: %opt %defaultLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,simplifycfg),default<O2>" -S %s -o %t
; RUN: %lli %t
; RUN: %FileCheck %s --check-prefix=STRICT < %t
; RUN: %opt %defaultLoadEnzyme -enzyme-fast-math=true -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,simplifycfg)" -S %s | %FileCheck %s --check-prefix=FAST
;
; The reverse derivative is (exp(log(x*c)) / (x*c)) * c. Reassociation
; changes this to (exp(log(x*c)) * c) / (x*c), underflowing before the
; division restores the scale. The noinline entry keeps O2 from replacing
; the runtime derivative check with a constant-folded specialization.
; Exercise the default, with no enzyme-fast-math option, after optimization.
;
; STRICT-LABEL: define double @dtiny(
; STRICT-NOT: fast
; STRICT: fdiv double
; STRICT: fmul double
; STRICT: ret double
;
; FAST-LABEL: define internal {{.*}}@diffe
; FAST: fmul fast double
; FAST: fdiv fast double

declare double @llvm.log.f64(double)
declare double @llvm.exp.f64(double)
declare double @llvm.fabs.f64(double)
declare double @__enzyme_autodiff(double (double)*, ...)

define double @wrapped_log(double %x) noinline nounwind readnone "enzyme_math"="log" {
  %v = call double @llvm.log.f64(double %x)
  ret double %v
}
define double @wrapped_exp(double %x) noinline nounwind readnone "enzyme_math"="exp" {
  %v = call double @llvm.exp.f64(double %x)
  ret double %v
}

define double @tiny(double %x) {
  %y = fmul double %x, 1.0e-190
  %l = call double @wrapped_log(double %y)
  %e = call double @wrapped_exp(double %l)
  ret double %e
}

define double @dtiny(double %x) noinline {
  %d = call double (double (double)*, ...) @__enzyme_autodiff(double (double)* @tiny, double %x)
  ret double %d
}

define i32 @main() {
  %d = call double @dtiny(double 1.0)
  %ratio = fdiv double %d, 1.0e-190
  %err = fsub double %ratio, 1.0
  %abs = call double @llvm.fabs.f64(double %err)
  %ok = fcmp olt double %abs, 1.0e-12
  %status = select i1 %ok, i32 0, i32 1
  ret i32 %status
}
