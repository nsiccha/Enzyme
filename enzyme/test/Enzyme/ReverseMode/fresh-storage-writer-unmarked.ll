; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; The later call writes through a pointer loaded from an allocation whose
; allocator does not declare that field fresh.

declare void @__enzyme_autodiff(...)
declare noalias ptr @enzyme_allocator(i64) #0
declare void @consume(ptr) readonly nofree "enzyme_inactive"

define internal double @sqdist(ptr %arr, double %m) {
entry:
  %data = load ptr, ptr %arr
  %np = getelementptr inbounds i8, ptr %arr, i64 8
  %n = load i64, ptr %np
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %inc, %loop ]
  %acc = phi double [ 0.0, %entry ], [ %acc.next, %loop ]
  %p = getelementptr inbounds double, ptr %data, i64 %i
  %y = load double, ptr %p
  %d = fsub double %y, %m
  %sq = fmul double %d, %d
  %acc.next = fadd double %acc, %sq
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %acc.next
}

define internal ptr @doses(ptr %arr, i1 %c) {
entry:
  %out = call noalias ptr @enzyme_allocator(i64 8)
  %src = load ptr, ptr %arr
  %x = load double, ptr %src
  %e = fadd double %x, 1.0
  %dst = load ptr, ptr %out
  store double %e, ptr %dst
  ret ptr %out
}

define double @f(ptr %arr, double %m, i1 %c) {
entry:
  %r = call double @sqdist(ptr %arr, double %m)
  %v = call ptr @doses(ptr %arr, i1 %c)
  call void @consume(ptr %v)
  ret double %r
}

define void @test(ptr %arr, double %m, i1 %c) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %arr, double %m, metadata !"enzyme_const", i1 %c)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_inactive" }

; CHECK: define internal {{.*}} @augmented_sqdist(
; CHECK: call {{.*}} @malloc(
