; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -enzyme-reverse-loop-entry-recompute=0 -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s --check-prefix=OFF

; The reverse of the inner loop uses %s, a value of the outer loop's body that
; does not change in the inner loop, in two arms. It is recomputed from memory
; nothing overwrites, so no cache is needed. It should be recomputed once on each
; entry of the inner loop's reverse, which dominates both arms, rather than in
; each arm on each iteration.
define double @nest(double* noalias %x, double* noalias %scales, i64 %n, i64 %m) {
entry:
  br label %outer

outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  %acc = phi double [ 0.000000e+00, %entry ], [ %acc.exit, %outer.latch ]
  %s.ptr = getelementptr inbounds double, double* %scales, i64 %j
  %s = load double, double* %s.ptr, align 8
  br label %inner

inner:
  %k = phi i64 [ 0, %outer ], [ %k.next, %inner.latch ]
  %sum = phi double [ %acc, %outer ], [ %sum.next, %inner.latch ]
  %x.ptr = getelementptr inbounds double, double* %x, i64 %k
  %xk = load double, double* %x.ptr, align 8
  %neg = fcmp olt double %xk, 0.000000e+00
  br i1 %neg, label %armA, label %armB

armA:
  %a = fmul double %xk, %s
  br label %inner.latch

armB:
  %b = fdiv double %xk, %s
  br label %inner.latch

inner.latch:
  %v = phi double [ %a, %armA ], [ %b, %armB ]
  %sum.next = fadd double %sum, %v
  %k.next = add nuw nsw i64 %k, 1
  %inner.done = icmp eq i64 %k.next, %m
  br i1 %inner.done, label %outer.latch, label %inner

outer.latch:
  %acc.exit = phi double [ %sum.next, %inner.latch ]
  %j.next = add nuw nsw i64 %j, 1
  %outer.done = icmp eq i64 %j.next, %n
  br i1 %outer.done, label %exit, label %outer

exit:
  %r = phi double [ %acc.exit, %outer.latch ]
  ret double %r
}

; A definition inside the loop it is used in must stay there: %t depends on the
; inner iteration, and its use reads it for that iteration.
define double @notinvariant(double* noalias %x, double* noalias %scales, i64 %m) {
entry:
  br label %inner

inner:
  %k = phi i64 [ 0, %entry ], [ %k.next, %inner ]
  %sum = phi double [ 0.000000e+00, %entry ], [ %sum.next, %inner ]
  %x.ptr = getelementptr inbounds double, double* %x, i64 %k
  %xk = load double, double* %x.ptr, align 8
  %t.ptr = getelementptr inbounds double, double* %scales, i64 %k
  %t = load double, double* %t.ptr, align 8
  %v = fmul double %xk, %t
  %sum.next = fadd double %sum, %v
  %k.next = add nuw nsw i64 %k, 1
  %inner.done = icmp eq i64 %k.next, %m
  br i1 %inner.done, label %exit, label %inner

exit:
  ret double %sum.next
}

; A second exit that returns: the reverse of the loop has two entries, so neither
; dominates its blocks, and %s is recomputed where it is used.
define double @twoexits(double* noalias %x, double* noalias %scales, i64 %n, i64 %m) {
entry:
  br label %outer

outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  %acc = phi double [ 0.000000e+00, %entry ], [ %sum.next, %outer.latch ]
  %s.ptr = getelementptr inbounds double, double* %scales, i64 %j
  %s = load double, double* %s.ptr, align 8
  br label %inner

inner:
  %k = phi i64 [ 0, %outer ], [ %k.next, %inner.latch ]
  %sum = phi double [ %acc, %outer ], [ %sum.next, %inner.latch ]
  %x.ptr = getelementptr inbounds double, double* %x, i64 %k
  %xk = load double, double* %x.ptr, align 8
  %v = fmul double %xk, %s
  %sum.next = fadd double %sum, %v
  %big = fcmp ogt double %sum.next, 1.000000e+01
  br i1 %big, label %early, label %inner.latch

inner.latch:
  %k.next = add nuw nsw i64 %k, 1
  %inner.done = icmp eq i64 %k.next, %m
  br i1 %inner.done, label %outer.latch, label %inner

early:
  %e = phi double [ %sum.next, %inner ]
  br label %exit

outer.latch:
  %j.next = add nuw nsw i64 %j, 1
  %outer.done = icmp eq i64 %j.next, %n
  br i1 %outer.done, label %done, label %outer

done:
  %d = phi double [ %sum.next, %outer.latch ]
  br label %exit

exit:
  %r = phi double [ %e, %early ], [ %d, %done ]
  ret double %r
}

declare double @__enzyme_autodiff(i8*, ...)

define void @dnest(double* %x, double* %dx, double* %scales, i64 %n, i64 %m) {
entry:
  %0 = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double*, double*, i64, i64)* @nest to i8*), metadata !"enzyme_dup", double* %x, double* %dx, metadata !"enzyme_const", double* %scales, metadata !"enzyme_const", i64 %n, metadata !"enzyme_const", i64 %m)
  ret void
}

define void @dnotinvariant(double* %x, double* %dx, double* %scales, i64 %m) {
entry:
  %0 = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double*, double*, i64)* @notinvariant to i8*), metadata !"enzyme_dup", double* %x, double* %dx, metadata !"enzyme_const", double* %scales, metadata !"enzyme_const", i64 %m)
  ret void
}

define void @dtwoexits(double* %x, double* %dx, double* %scales, i64 %n, i64 %m) {
entry:
  %0 = call double (i8*, ...) @__enzyme_autodiff(i8* bitcast (double (double*, double*, i64, i64)* @twoexits to i8*), metadata !"enzyme_dup", double* %x, double* %dx, metadata !"enzyme_const", double* %scales, metadata !"enzyme_const", i64 %n, metadata !"enzyme_const", i64 %m)
  ret void
}

; CHECK-LABEL: define internal void @diffenest
; CHECK: invertarmA:
; CHECK-NEXT:   %{{.+}} = fmul fast double %{{.+}}, %s_unwrap
; CHECK-NEXT:   br label %invertinner
; CHECK: invertarmB:
; CHECK-NEXT:   %{{.+}} = fdiv fast double %{{.+}}, %s_unwrap
; CHECK-NEXT:   br label %invertinner
; CHECK: invertouter.latch:
; CHECK:   %"iv'ac.0" = phi i64
; CHECK-NEXT:   %s.ptr_unwrap = getelementptr inbounds double, double* %scales, i64 %"iv'ac.0"
; CHECK-NEXT:   %s_unwrap = load double, double* %s.ptr_unwrap
; CHECK-NEXT:   br label %invertinner.latch

; OFF-LABEL: define internal void @diffenest
; OFF: invertarmA:
; OFF-NEXT:   %s.ptr_unwrap = getelementptr inbounds double, double* %scales, i64 %"iv'ac.0"
; OFF-NEXT:   %s_unwrap = load double, double* %s.ptr_unwrap
; OFF: invertarmB:
; OFF-NEXT:   %[[ptr:.+]] = getelementptr inbounds double, double* %scales, i64 %"iv'ac.0"
; OFF-NEXT:   %[[val:.+]] = load double, double* %[[ptr]]
; OFF-NEXT:   %{{.+}} = fdiv fast double %{{.+}}, %[[val]]

; CHECK-LABEL: define internal void @diffenotinvariant
; CHECK: invertinner:
; CHECK:   %"iv'ac.0" = phi i64
; CHECK:   %t.ptr_unwrap = getelementptr inbounds double, double* %scales, i64 %"iv'ac.0"
; CHECK-NEXT:   %t_unwrap = load double, double* %t.ptr_unwrap

; CHECK-LABEL: define internal void @diffetwoexits
; CHECK: invertinner:
; CHECK:   %s.ptr_unwrap = getelementptr inbounds double, double* %scales, i64 %"iv'ac.0"
; CHECK-NEXT:   %s_unwrap = load double, double* %s.ptr_unwrap
; CHECK: invertinner.latch:
