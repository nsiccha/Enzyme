; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme,function(mem2reg,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s; fi

; As rewritten-slot-loop.ll, but the value stored into the slot alternates
; between two arrays, so a later store changes what the reader read through
; the slot: the reader still caches its inputs.

declare void @__enzyme_autodiff(...)
declare void @consume(ptr) readonly nofree "enzyme_inactive"
declare void @publish(ptr) nofree "enzyme_inactive"
declare void @llvm.lifetime.start.p0(i64, ptr nocapture)
declare void @llvm.lifetime.end.p0(i64, ptr nocapture)

define internal double @sqdist_ref(ptr nocapture readonly %ref, double %m) {
entry:
  %arr = load ptr, ptr %ref
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

define double @f(ptr %arr, ptr %other, double %m, i64 %n) {
entry:
  %slot = alloca ptr, align 8
  call void @llvm.lifetime.start.p0(i64 8, ptr %slot)
  store ptr null, ptr %slot
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %inc, %loop ]
  %total = phi double [ 0.0, %entry ], [ %next, %loop ]
  %odd = trunc i64 %i to i1
  %value = select i1 %odd, ptr %other, ptr %arr
  store ptr %value, ptr %slot
  %r = call double @sqdist_ref(ptr nocapture readonly %slot, double %m)
  %next = fadd double %total, %r
  %inc = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  call void @llvm.lifetime.end.p0(i64 8, ptr %slot)
  ret double %next
}

define void @test(ptr %arr, ptr %other, double %m, i64 %n) {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, metadata !"enzyme_const", ptr %arr, metadata !"enzyme_const", ptr %other, double %m, i64 %n)
  ret void
}

; The reader keeps what it loaded through the slot on its tape.
; CHECK: define internal { double } @diffesqdist_ref(ptr nocapture readonly %ref, double %m, double %differeturn, {{.+}})
