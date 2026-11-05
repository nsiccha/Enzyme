; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme-preopt=false -enzyme -mem2reg -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s
; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -enzyme-recompute-branch-predicates=0 -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -S | FileCheck %s --check-prefix=OFF

; The reverse of a block that the forward pass reached from one of several
; predecessors must branch to the reverse of the predecessor it came from.
; With four or more predecessors that choice was always cached, one entry per
; loop iteration, even when the branch conditions that made it can simply be
; recomputed. Here they are: each is a comparison of a value of the loop body
; that the reverse pass recomputes anyway (the shape of LogExpFunctions'
; log1pexp, inlined in a loop).
define double @fourarms(double* noalias %x, double %s, i64 %n) {
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %merge ]
  %acc = phi double [ 0.000000e+00, %entry ], [ %acc.next, %merge ]
  %xi.ptr = getelementptr inbounds double, double* %x, i64 %i
  %xi = load double, double* %xi.ptr, align 8
  %t = fmul double %xi, %s
  %small = fcmp ult double %t, -3.700000e+01
  br i1 %small, label %armA, label %b1

armA:
  %eA = call double @llvm.exp.f64(double %t)
  br label %merge

b1:
  %mid = fcmp ult double %t, 1.800000e+01
  br i1 %mid, label %armB, label %b2

armB:
  %eB = call double @llvm.exp.f64(double %t)
  %lB = call double @log1p(double %eB)
  br label %merge

b2:
  %big = fcmp ult double %t, 3.300000e+01
  br i1 %big, label %armC, label %armD

armC:
  %nt = fneg double %t
  %eC = call double @llvm.exp.f64(double %nt)
  %vC = fadd double %t, %eC
  br label %merge

armD:
  br label %merge

merge:
  %v = phi double [ %eA, %armA ], [ %lB, %armB ], [ %vC, %armC ], [ %t, %armD ]
  %acc.next = fadd double %acc, %v
  %i.next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %i.next, %n
  br i1 %done, label %exit, label %loop

exit:
  ret double %acc.next
}

; The second split reads its condition from memory in a block that does not
; run on every path into the merge. Evaluating it on the other paths could
; read memory the forward pass never read, so the choice stays cached.
define double @guarded(double* noalias %x, i64* noalias %k, double %s, i64 %n) {
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %merge ]
  %acc = phi double [ 0.000000e+00, %entry ], [ %acc.next, %merge ]
  %xi.ptr = getelementptr inbounds double, double* %x, i64 %i
  %xi = load double, double* %xi.ptr, align 8
  %t = fmul double %xi, %s
  %small = fcmp ult double %t, 0.000000e+00
  br i1 %small, label %armA, label %b1

armA:
  %eA = call double @llvm.exp.f64(double %t)
  br label %merge

b1:
  %ki.ptr = getelementptr inbounds i64, i64* %k, i64 %i
  %ki = load i64, i64* %ki.ptr, align 8
  %zero = icmp eq i64 %ki, 0
  br i1 %zero, label %armB, label %b2

armB:
  %eB = call double @llvm.exp.f64(double %t)
  %lB = call double @log1p(double %eB)
  br label %merge

b2:
  %big = fcmp ult double %t, 3.300000e+01
  br i1 %big, label %armC, label %armD

armC:
  %vC = fmul double %t, %t
  br label %merge

armD:
  br label %merge

merge:
  %v = phi double [ %eA, %armA ], [ %lB, %armB ], [ %vC, %armC ], [ %t, %armD ]
  %acc.next = fadd double %acc, %v
  %i.next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %i.next, %n
  br i1 %done, label %exit, label %loop

exit:
  ret double %acc.next
}

define void @test(double* %x, double* %dx, i64* %k, double %s, i64 %n) {
entry:
  %r0 = call double (...) @__enzyme_autodiff(double (double*, double, i64)* @fourarms, metadata !"enzyme_dup", double* %x, double* %dx, double %s, i64 %n)
  %r1 = call double (...) @__enzyme_autodiff(double (double*, i64*, double, i64)* @guarded, metadata !"enzyme_dup", double* %x, double* %dx, metadata !"enzyme_const", i64* %k, double %s, i64 %n)
  ret void
}

declare double @llvm.exp.f64(double)
declare double @log1p(double)
declare double @__enzyme_autodiff(...)

; The reverse of %merge recomputes the three comparisons from the reloaded
; x[i] and switches on the arm they select: no cache, so no buffer.
; CHECK-LABEL: define internal { double } @diffefourarms(
; CHECK-NOT: @malloc
; CHECK-NOT: @free
; CHECK: invertmerge:
; CHECK:   %xi_unwrap{{[0-9]*}} = load double, {{.*}} %xi.ptr_unwrap
; CHECK-NEXT:   %[[t:.+]] = fmul double %xi_unwrap{{[0-9]*}}, %s
; CHECK-NEXT:   %small_unwrap = fcmp ult double %[[t]], -3.700000e+01
; CHECK:   %mid_unwrap = fcmp ult double %[[t]], 1.800000e+01
; CHECK:   %big_unwrap = fcmp ult double %[[t]], 3.300000e+01
; CHECK:   %[[w2:.+]] = select i1 %{{.+}}, i8 2, i8 3
; CHECK-NEXT:   %[[w1:.+]] = select i1 %{{.+}}, i8 1, i8 %[[w2]]
; CHECK-NEXT:   %[[w0:.+]] = select i1 %small_unwrap, i8 0, i8 %[[w1]]
; CHECK-NEXT:   switch i8 %[[w0]], label %invertloop [
; CHECK-NEXT:     i8 0, label %invertarmA
; CHECK-NEXT:     i8 1, label %invertarmB
; CHECK-NEXT:     i8 2, label %invertarmC
; CHECK-NEXT:   ]
; CHECK-NEXT: }

; CHECK-LABEL: define internal { double } @diffeguarded(
; CHECK: entry:
; CHECK:   %malloccall = tail call noalias nonnull {{.*}}@malloc(i64 %n), !enzyme_cache_alloc
; CHECK: b1:
; CHECK:   %ki = load i64
; CHECK: invertmerge:
; CHECK:   switch i8

; With the option off, the choice is cached in both: one entry per iteration.
; OFF-LABEL: define internal { double } @diffefourarms(
; OFF: entry:
; OFF:   %malloccall = tail call noalias nonnull {{.*}}@malloc(i64 %n), !enzyme_cache_alloc
; OFF: invertentry:
; OFF:   tail call void @free(
; OFF-LABEL: define internal { double } @diffeguarded(
; OFF: entry:
; OFF:   %malloccall = tail call noalias nonnull {{.*}}@malloc(i64 %n), !enzyme_cache_alloc
