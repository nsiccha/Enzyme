; RUN: %opt < %s %newLoadEnzyme -enzyme-preopt=false -passes="enzyme,verify" -S | FileCheck %s

declare token @llvm.julia.gc_preserve_begin(...)
declare void @llvm.julia.gc_preserve_end(token)
declare i8* @__enzyme_virtualreverse(...)

; Either end can branch to either destination, in opposite orders. A path
; that skips the begin also reaches the destinations. Values carried out of
; each arm must still reach the right successor PHIs after merging the ends.
define double @f({} addrspace(10)* %root, double %x, i1 %enter, i1 %arm,
                 i1 %left, i1 %right) {
entry:
  br i1 %enter, label %begin, label %bypass
begin:
  %tok = call token (...) @llvm.julia.gc_preserve_begin({} addrspace(10)* %root)
  br i1 %arm, label %a, label %b
a:
  %a.val = fmul double %x, %x
  call void @llvm.julia.gc_preserve_end(token %tok)
  br i1 %left, label %first, label %second
b:
  %b.val = fadd double %x, %x
  call void @llvm.julia.gc_preserve_end(token %tok)
  br i1 %right, label %second, label %first
bypass:
  br i1 %arm, label %first, label %second
first:
  %p = phi double [ %a.val, %a ], [ %b.val, %b ], [ %x, %bypass ]
  br label %exit
second:
  %q = phi double [ %x, %a ], [ %b.val, %b ], [ 0.0, %bypass ]
  %r = fmul double %q, %x
  br label %exit
exit:
  %result = phi double [ %p, %first ], [ %r, %second ]
  ret double %result
}

define i8* @test() {
  %r = call i8* (...) @__enzyme_virtualreverse(double ({} addrspace(10)*, double, i1, i1, i1, i1)* @f)
  ret i8* %r
}

; CHECK-LABEL: define internal {{.*}} @augmented_f(
; CHECK: %[[TOK:.+]] = call token (...) @llvm.julia.gc_preserve_begin(
; CHECK-NOT: @llvm.julia.gc_preserve_end
; CHECK: gcpreserve.guard:
; CHECK: call void @llvm.julia.gc_preserve_end(token %[[TOK]])
; CHECK: br i1
; CHECK-NOT: @llvm.julia.gc_preserve_end
; CHECK-LABEL: define internal {{.*}} @diffef(
; CHECK: invertbegin:
; CHECK: call void @llvm.julia.gc_preserve_end(token %[[REV:[a-zA-Z0-9_.]+]])
; CHECK: invertgcpreserve.guard:
; CHECK: %[[REV]] = call token (...) @llvm.julia.gc_preserve_begin(
