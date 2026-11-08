; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -enzyme-reverse-loop-entry-merges=0 -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s --check-prefix=OFF

declare double @exp(double)

define double @callee(double %x) {
entry:
  %m = fmul double %x, %x
  ret double %m
}

; %w merges two arms of the outer loop's body, and the inner loop reads it in
; every iteration. One arm reads the result of a call, which the reverse pass
; caches; the other computes from memory nothing overwrites. The reverse pass
; should rebuild %w once on each entry of the inner loop's reverse, in the
; reverse of the inner loop's exit, not on each iteration.
define double @merge(double* noalias %x, double* noalias %scales, i64 %n, i64 %m) {
entry:
  br label %outer

outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  %acc = phi double [ 0.000000e+00, %entry ], [ %sum.next, %outer.latch ]
  %s.ptr = getelementptr inbounds double, double* %scales, i64 %j
  %s = load double, double* %s.ptr, align 8
  %small = fcmp olt double %s, 1.000000e-01
  br i1 %small, label %poly, label %rational

poly:
  %c = call double @callee(double %s)
  %p = fmul double %s, %c
  br label %merged

rational:
  %neg = fneg double %s
  %e = call double @exp(double %neg)
  %q = fdiv double %e, %s
  br label %merged

merged:
  %w = phi double [ %p, %poly ], [ %q, %rational ]
  br label %inner

inner:
  %k = phi i64 [ 0, %merged ], [ %k.next, %inner ]
  %sum = phi double [ %acc, %merged ], [ %sum.next, %inner ]
  %x.ptr = getelementptr inbounds double, double* %x, i64 %k
  %xk = load double, double* %x.ptr, align 8
  %v = fmul double %xk, %w
  %u = fmul double %v, %xk
  %sum.next = fadd double %sum, %u
  %k.next = add nuw nsw i64 %k, 1
  %inner.done = icmp eq i64 %k.next, %m
  br i1 %inner.done, label %outer.latch, label %inner

outer.latch:
  %j.next = add nuw nsw i64 %j, 1
  %outer.done = icmp eq i64 %j.next, %n
  br i1 %outer.done, label %exit, label %outer

exit:
  ret double %sum.next
}

; The same with the inner loop's exit laid out before the loop, as Julia lays out
; a loop whose body starts with a bounds check. The reverse of the exit is then
; finished, terminator included, when the loop's reverse first asks for %w.
define double @exitfirst(double* noalias %x, double* noalias %scales, i64 %n, i64 %m) {
entry:
  br label %outer

outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  %acc = phi double [ 0.000000e+00, %entry ], [ %sum.next, %outer.latch ]
  %s.ptr = getelementptr inbounds double, double* %scales, i64 %j
  %s = load double, double* %s.ptr, align 8
  %small = fcmp olt double %s, 1.000000e-01
  br i1 %small, label %poly, label %rational

poly:
  %c = call double @callee(double %s)
  %p = fmul double %s, %c
  br label %merged

rational:
  %neg = fneg double %s
  %e = call double @exp(double %neg)
  %q = fdiv double %e, %s
  br label %merged

merged:
  %w = phi double [ %p, %poly ], [ %q, %rational ]
  br label %inner

outer.latch:
  %j.next = add nuw nsw i64 %j, 1
  %outer.done = icmp eq i64 %j.next, %n
  br i1 %outer.done, label %exit, label %outer

exit:
  ret double %sum.next

inner:
  %k = phi i64 [ 0, %merged ], [ %k.next, %inner ]
  %sum = phi double [ %acc, %merged ], [ %sum.next, %inner ]
  %x.ptr = getelementptr inbounds double, double* %x, i64 %k
  %xk = load double, double* %x.ptr, align 8
  %v = fmul double %xk, %w
  %u = fmul double %v, %xk
  %sum.next = fadd double %sum, %u
  %k.next = add nuw nsw i64 %k, 1
  %inner.done = icmp eq i64 %k.next, %m
  br i1 %inner.done, label %outer.latch, label %inner
}

; A merge that depends on the inner loop's own iteration stays where it is used.
define double @innermerge(double* noalias %x, double* noalias %scales, i64 %m) {
entry:
  %s = load double, double* %scales, align 8
  br label %inner

inner:
  %k = phi i64 [ 0, %entry ], [ %k.next, %inner.latch ]
  %sum = phi double [ 0.000000e+00, %entry ], [ %sum.next, %inner.latch ]
  %x.ptr = getelementptr inbounds double, double* %x, i64 %k
  %xk = load double, double* %x.ptr, align 8
  %neg = fcmp olt double %xk, 0.000000e+00
  br i1 %neg, label %armA, label %armB

armA:
  %a = fmul double %s, %s
  br label %inner.latch

armB:
  %b = fdiv double %s, %xk
  br label %inner.latch

inner.latch:
  %w = phi double [ %a, %armA ], [ %b, %armB ]
  %v = fmul double %xk, %w
  %sum.next = fadd double %sum, %v
  %k.next = add nuw nsw i64 %k, 1
  %inner.done = icmp eq i64 %k.next, %m
  br i1 %inner.done, label %exit, label %inner

exit:
  ret double %sum.next
}

; A running value of the outer loop is not one value per entry of the inner loop
; that can be rebuilt from its arms: its phi is loop-carried.
define double @carried(double* noalias %x, double* noalias %scales, i64 %n, i64 %m) {
entry:
  br label %outer

outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  %acc = phi double [ 0.000000e+00, %entry ], [ %sum.next, %outer.latch ]
  %r = phi double [ 1.000000e+00, %entry ], [ %r.next, %outer.latch ]
  br label %inner

inner:
  %k = phi i64 [ 0, %outer ], [ %k.next, %inner ]
  %sum = phi double [ %acc, %outer ], [ %sum.next, %inner ]
  %x.ptr = getelementptr inbounds double, double* %x, i64 %k
  %xk = load double, double* %x.ptr, align 8
  %v = fmul double %xk, %r
  %u = fmul double %v, %xk
  %sum.next = fadd double %sum, %u
  %k.next = add nuw nsw i64 %k, 1
  %inner.done = icmp eq i64 %k.next, %m
  br i1 %inner.done, label %outer.latch, label %inner

outer.latch:
  %s.ptr = getelementptr inbounds double, double* %scales, i64 %j
  %s = load double, double* %s.ptr, align 8
  %r.next = fmul double %r, %s
  %j.next = add nuw nsw i64 %j, 1
  %outer.done = icmp eq i64 %j.next, %n
  br i1 %outer.done, label %exit, label %outer

exit:
  ret double %sum.next
}

declare double @__enzyme_autodiff(i8*, ...)

define void @dmerge(double* %x, double* %dx, double* %scales, double* %dscales, i64 %n, i64 %m) {
entry:
  %0 = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double*, double*, i64, i64)* @merge to i8*), metadata !"enzyme_dup", double* %x, double* %dx, metadata !"enzyme_dup", double* %scales, double* %dscales, metadata !"enzyme_const", i64 %n, metadata !"enzyme_const", i64 %m)
  ret void
}

define void @dexitfirst(double* %x, double* %dx, double* %scales, double* %dscales, i64 %n, i64 %m) {
entry:
  %0 = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double*, double*, i64, i64)* @exitfirst to i8*), metadata !"enzyme_dup", double* %x, double* %dx, metadata !"enzyme_dup", double* %scales, double* %dscales, metadata !"enzyme_const", i64 %n, metadata !"enzyme_const", i64 %m)
  ret void
}

define void @dinnermerge(double* %x, double* %dx, double* %scales, double* %dscales, i64 %m) {
entry:
  %0 = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double*, double*, i64)* @innermerge to i8*), metadata !"enzyme_dup", double* %x, double* %dx, metadata !"enzyme_dup", double* %scales, double* %dscales, metadata !"enzyme_const", i64 %m)
  ret void
}

define void @dcarried(double* %x, double* %dx, double* %scales, double* %dscales, i64 %n, i64 %m) {
entry:
  %0 = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double*, double*, i64, i64)* @carried to i8*), metadata !"enzyme_dup", double* %x, double* %dx, metadata !"enzyme_dup", double* %scales, double* %dscales, metadata !"enzyme_const", i64 %n, metadata !"enzyme_const", i64 %m)
  ret void
}

; CHECK-LABEL: define internal void @diffemerge
; CHECK: invertinner:
; CHECK-NOT: _phirc
; CHECK: invertouter.latch:
; CHECK-NOT: invertinner:
; CHECK:   br i1 %{{.+}}, label %invertouter.latch_phirc, label %invertouter.latch_phirc{{[0-9]+}}
; CHECK: invertouter.latch_phirc:
; CHECK:   %c_malloccache
; CHECK:   %p_unwrap = fmul
; CHECK: invertouter.latch_phirc{{[0-9]+}}:
; CHECK:   fneg
; CHECK:   call {{.*}}double @exp(
; CHECK:   %q_unwrap = fdiv
; CHECK:   %{{.+}} = phi{{( [a-z]+)*}} double [ %p_unwrap, %invertouter.latch_phirc ], [ %q_unwrap, %invertouter.latch_phirc{{[0-9]+}} ]
; CHECK-NEXT:   br label %invertinner

; OFF-LABEL: define internal void @diffemerge
; OFF: invertinner:
; OFF:   br i1 %{{.+}}, label %invertinner_phirc, label %invertinner_phirc{{[0-9]+}}

; CHECK-LABEL: define internal void @diffeexitfirst
; CHECK: invertouter.latch:
; CHECK-NOT: invertinner:
; CHECK:   br i1 %{{.+}}, label %invertouter.latch_phirc, label %invertouter.latch_phirc{{[0-9]+}}
; CHECK:   %{{.+}} = phi{{( [a-z]+)*}} double [ %p_unwrap, %invertouter.latch_phirc ], [ %q_unwrap, %invertouter.latch_phirc{{[0-9]+}} ]
; CHECK-NEXT:   br label %invertinner
; CHECK: invertinner:
; CHECK-NOT: _phirc
; CHECK: incinvertinner:

; OFF-LABEL: define internal void @diffeexitfirst
; OFF: invertinner:
; OFF:   br i1 %{{.+}}, label %invertinner_phirc, label %invertinner_phirc{{[0-9]+}}

; CHECK-LABEL: define internal void @diffeinnermerge
; CHECK: invertinner.latch:
; CHECK:   br i1 %neg_unwrap, label %invertinner.latch_phirc, label %invertinner.latch_phirc{{[0-9]+}}

; CHECK-LABEL: define internal void @diffecarried
; CHECK: invertinner:
; CHECK:   getelementptr inbounds double, double* %r_malloccache, i64 %"iv'ac.0"
; CHECK: incinvertinner:
