; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s --check-prefixes=CHECK,COMMON; fi
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s --check-prefixes=CHECK,COMMON
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -enzyme-reverse-loop-entry-recompute=0 -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s --check-prefixes=OFF,COMMON
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -enzyme-register-reduce=1 -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s --check-prefixes=OFF,COMMON

; The call cannot be recomputed, but its forward SSA result dominates every
; return. lookupM uses that result directly, so it must not prevent log from
; being recomputed once on entry to the reverse loop. Keeping scale live after
; the loop reproduces the prior-term liveness pattern of a mixture likelihood.
; Neither the opaque call nor the guarded log may be speculated or duplicated.
declare double @opaque_scale() nounwind readnone
declare double @log(double) nounwind readnone

define double @available_input(double* noalias %x, i64 %n) {
entry:
  %scale = call double @opaque_scale()
  %nonempty = icmp sgt i64 %n, 0
  br i1 %nonempty, label %preheader, label %exit
preheader:
  %ls = call double @log(double %scale)
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %sum = phi double [ 0.000000e+00, %preheader ], [ %sum.next, %loop ]
  %p = getelementptr inbounds double, double* %x, i64 %i
  %v = load double, double* %p
  %sq = fmul double %v, %v
  %term = fmul double %sq, %ls
  %sum.next = fadd double %sum, %term
  %next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %loopexit, label %loop
loopexit:
  %result = phi double [ %sum.next, %loop ]
  br label %exit
exit:
  %answer = phi double [ 0.000000e+00, %entry ], [ %result, %loopexit ]
  %withprior = fadd double %answer, %scale
  ret double %withprior
}

declare double @__enzyme_autodiff(i8*, ...)
define void @davailable_input(double* %x, double* %dx, i64 %n) {
  %r = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double*, i64)* @available_input to i8*), metadata !"enzyme_dup", double* %x, double* %dx, metadata !"enzyme_const", i64 %n)
  ret void
}

define double @overwritten_input(double* noalias %x, double* noalias %scales, i64 %n) {
entry:
  %scale = load double, double* %scales
  %nonempty = icmp sgt i64 %n, 0
  br i1 %nonempty, label %preheader, label %exit
preheader:
  %ls = call double @log(double %scale)
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %sum = phi double [ 0.000000e+00, %preheader ], [ %sum.next, %loop ]
  %p = getelementptr inbounds double, double* %x, i64 %i
  %v = load double, double* %p
  %sq = fmul double %v, %v
  %term = fmul double %sq, %ls
  %sum.next = fadd double %sum, %term
  %next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %loopexit, label %loop
loopexit:
  %result = phi double [ %sum.next, %loop ]
  br label %exit
exit:
  %answer = phi double [ 0.000000e+00, %entry ], [ %result, %loopexit ]
  store double 0.000000e+00, double* %scales
  ret double %answer
}

define void @doverwritten_input(double* %x, double* %dx, double* %scales, i64 %n) {
  %r = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double*, double*, i64)* @overwritten_input to i8*), metadata !"enzyme_dup", double* %x, double* %dx, metadata !"enzyme_const", double* %scales, metadata !"enzyme_const", i64 %n)
  ret void
}

; COMMON-LABEL: define internal void @diffeavailable_input(
; COMMON: entry:
; COMMON: %scale = call double @opaque_scale()
; COMMON-NOT: call double @opaque_scale()
; COMMON: invertloop:
; CHECK-NOT: call double @log(
; OFF: call double @log(double %scale)
; COMMON: br i1 {{.*}}, label %invertentry, label %incinvertloop
; COMMON: incinvertloop:
; COMMON: br label %invertloop
; COMMON: invertloopexit:
; CHECK: call double @log(double %scale)
; OFF-NOT: call double @log(
; COMMON: br label %invertloop
; COMMON: invertexit:
; COMMON: br i1 %nonempty{{(_unwrap)?}}, label %invertloopexit, label %invertentry
; COMMON: }

; An overwritten input still needs its forward log cached. Availability of a
; forward SSA value must not authorize reloading the memory that held it.
; COMMON-LABEL: define internal void @diffeoverwritten_input(
; COMMON: entry:
; COMMON: %scale = load double,
; COMMON: preheader:
; COMMON: %ls = call double @log(double %scale)
; COMMON: exit:
; COMMON: [[CACHED:%.*]] = phi double [ undef, %entry ], [ %ls, %loop ]
; COMMON: store double 0.000000e+00,
; COMMON-NOT: call double @log(
; COMMON: invertloop:
; COMMON-NOT: call double @log(
; COMMON: fmul {{.*}}double {{.*}}, [[CACHED]]
; COMMON-NOT: call double @log(
; COMMON: invertloopexit:
; COMMON-NOT: call double @log(
; COMMON: }
