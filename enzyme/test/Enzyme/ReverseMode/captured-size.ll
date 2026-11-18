; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; Escaping a proven integer size does not expose the initialized buffer pointer.

declare void @__enzyme_autodiff(...)
declare void @free(ptr)
declare noalias ptr @enzyme_allocator(i64) #0
@captured_size = global i64 0

define double @f(ptr %arr, double %m) {
entry:
  %obj = call noalias ptr @enzyme_allocator(i64 16), !enzyme_deallocator_fn !0
  %sizep = getelementptr inbounds i8, ptr %obj, i64 8
  %n = load i64, ptr %sizep
  store i64 %n, ptr @captured_size
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %inc, %loop ]
  %acc = phi double [ 0.0, %entry ], [ %acc.next, %loop ]
  %data = load ptr, ptr %arr
  %p = getelementptr inbounds double, ptr %data, i64 %i
  %y = load double, ptr %p
  %d = fsub double %y, %m
  %sq = fmul double %d, %d
  %acc.next = fadd double %acc, %sq
  %buffer = load ptr, ptr %obj
  %q = getelementptr inbounds double, ptr %buffer, i64 %i
  store double 0.0, ptr %q
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  ret double %acc.next
}

define void @test(ptr %arr, double %m) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %arr, double %m)
  ret void
}

attributes #0 = { inaccessiblememonly "enzyme_allocator"="0" "enzyme_deallocator"="-1" "enzyme_inactive" }

!0 = !{ptr @free}

; CHECK: define internal { double } @diffef(
; CHECK-NOT: malloc
; CHECK: %y_unwrap = load double
; CHECK-NOT: malloc
; CHECK: }
