; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -enzyme-preopt=false -enzyme-julia-addr-load -passes=enzyme -S -o %t && FileCheck %s < %t && %lli %t; fi

; An allocation on the backedge is the previous iteration's allocation when
; reached through %prev. A single replay cache slot instead points at the new,
; uninitialized allocation when reconstructing its length. Keep the allocation
; instances from the forward pass so every reverse iteration gets its own one.
; The zero-filled allocator makes the old uninitialized read deterministic.

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128-ni:10:11:12:13"
target triple = "x86_64-linux-gnu"

declare noalias ptr @calloc(i64, i64)
define noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr %task, i64 %size, ptr addrspace(10) %type) noinline {
  %allocation = call ptr @calloc(i64 1, i64 %size)
  %result = addrspacecast ptr %allocation to ptr addrspace(10)
  ret ptr addrspace(10) %result
}

define double @carry_header(double %x, i64 %n, i64 %steps) {
entry:
  %seed = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr null, i64 8, ptr addrspace(10) null)
  store i64 %n, ptr addrspace(10) %seed
  br label %outer
outer:
  %i = phi i64 [0, %entry], [%inext, %exitinner]
  %prev = phi ptr addrspace(10) [%seed, %entry], [%next, %exitinner]
  %total = phi double [0.0, %entry], [%totalnext, %exitinner]
  %len = load i64, ptr addrspace(10) %prev
  %next = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj(ptr null, i64 8, ptr addrspace(10) null)
  %newlen = add i64 %len, 1
  store i64 %newlen, ptr addrspace(10) %next
  %empty = icmp eq i64 %len, 0
  br i1 %empty, label %exitinner, label %inner
inner:
  %j = phi i64 [0, %outer], [%jnext, %inner]
  %partial = phi double [0.0, %outer], [%pnext, %inner]
  %term = fmul double %x, %x
  %pnext = fadd double %partial, %term
  %jnext = add i64 %j, 1
  %done = icmp eq i64 %jnext, %len
  br i1 %done, label %exitinner, label %inner
exitinner:
  %value = phi double [0.0, %outer], [%pnext, %inner]
  %totalnext = fadd double %total, %value
  %inext = add i64 %i, 1
  %finished = icmp eq i64 %inext, %steps
  br i1 %finished, label %exit, label %outer
exit:
  ret double %totalnext
}

declare double @__enzyme_autodiff(...)
define double @driver(double %x, i64 %n, i64 %steps) {
  %dx = call double (...) @__enzyme_autodiff(ptr @carry_header, double %x, i64 %n, i64 %steps)
  ret double %dx
}

; Check initial lengths 0..3 and step counts 1..4 against
; d/dx sum(i=0..steps-1, (n+i)*x*x).
define i32 @main() {
entry:
  br label %sizes
sizes:
  %n = phi i64 [0, %entry], [%nnext, %sizesnext]
  br label %counts
counts:
  %steps = phi i64 [1, %sizes], [%snext, %valid]
  %gradient = call double @driver(double 2.0, i64 %n, i64 %steps)
  %base = mul i64 %n, %steps
  %less = sub i64 %steps, 1
  %product = mul i64 %steps, %less
  %triangle = lshr i64 %product, 1
  %coefficient = add i64 %base, %triangle
  %integer_expected = mul i64 %coefficient, 4
  %expected = uitofp i64 %integer_expected to double
  %ok = fcmp oeq double %gradient, %expected
  br i1 %ok, label %valid, label %fail
valid:
  %snext = add i64 %steps, 1
  %sdone = icmp eq i64 %snext, 5
  br i1 %sdone, label %sizesnext, label %counts
sizesnext:
  %nnext = add i64 %n, 1
  %ndone = icmp eq i64 %nnext, 4
  br i1 %ndone, label %pass, label %sizes
pass:
  ret i32 0
fail:
  ret i32 1
}

; CHECK-LABEL: define internal {{.*}} @diffecarry_header(
; CHECK: %next_{{(malloc)?cache}} =
; CHECK: %next = call noalias nonnull ptr addrspace(10) @julia.gc_alloc_obj
; CHECK-NOT: %remat_next =
; CHECK: {{^}}}
