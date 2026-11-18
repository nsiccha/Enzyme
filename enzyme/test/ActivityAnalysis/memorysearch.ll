; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -print-activity-analysis -activity-analysis-func=constant_then_active_store -activity-analysis-duplicated-ret=1 -o /dev/null | FileCheck %s --check-prefix=CONSTANT-THEN-ACTIVE-STORE; fi
; RUN: %opt < %s %newLoadEnzyme -passes="print-activity-analysis" -activity-analysis-func=constant_then_active_store -activity-analysis-duplicated-ret=1 -S | FileCheck %s --check-prefix=CONSTANT-THEN-ACTIVE-STORE
; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -print-activity-analysis -activity-analysis-func=only_constant_stores -activity-analysis-duplicated-ret=1 -o /dev/null | FileCheck %s --check-prefix=ONLY-CONSTANT-STORES; fi
; RUN: %opt < %s %newLoadEnzyme -passes="print-activity-analysis" -activity-analysis-func=only_constant_stores -activity-analysis-duplicated-ret=1 -S | FileCheck %s --check-prefix=ONLY-CONSTANT-STORES
; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -print-activity-analysis -activity-analysis-func=store_before_allocation_in_loop -activity-analysis-duplicated-ret=1 -o /dev/null | FileCheck %s --check-prefix=STORE-BEFORE-ALLOCATION-IN-LOOP; fi
; RUN: %opt < %s %newLoadEnzyme -passes="print-activity-analysis" -activity-analysis-func=store_before_allocation_in_loop -activity-analysis-duplicated-ret=1 -S | FileCheck %s --check-prefix=STORE-BEFORE-ALLOCATION-IN-LOOP
; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -print-activity-analysis -activity-analysis-func=store_on_unreachable_path -activity-analysis-duplicated-ret=1 -o /dev/null | FileCheck %s --check-prefix=STORE-ON-UNREACHABLE-PATH; fi
; RUN: %opt < %s %newLoadEnzyme -passes="print-activity-analysis" -activity-analysis-func=store_on_unreachable_path -activity-analysis-duplicated-ret=1 -S | FileCheck %s --check-prefix=STORE-ON-UNREACHABLE-PATH
; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -print-activity-analysis -activity-analysis-func=calls_that_do_not_store -activity-analysis-duplicated-ret=1 -o /dev/null | FileCheck %s --check-prefix=CALLS-THAT-DO-NOT-STORE; fi
; RUN: %opt < %s %newLoadEnzyme -passes="print-activity-analysis" -activity-analysis-func=calls_that_do_not_store -activity-analysis-duplicated-ret=1 -S | FileCheck %s --check-prefix=CALLS-THAT-DO-NOT-STORE
; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -print-activity-analysis -activity-analysis-func=ordered_load_of_known_integer -activity-analysis-duplicated-ret=1 -o /dev/null | FileCheck %s --check-prefix=ORDERED-LOAD-OF-KNOWN-INTEGER; fi
; RUN: %opt < %s %newLoadEnzyme -passes="print-activity-analysis" -activity-analysis-func=ordered_load_of_known_integer -activity-analysis-duplicated-ret=1 -S | FileCheck %s --check-prefix=ORDERED-LOAD-OF-KNOWN-INTEGER

; These pin what a search of memory concludes when it can skip work: instructions
; that are not memory accesses, known-inactive loads and stores, and the order in
; which it reaches the instructions that can follow an allocation.

declare noalias i8* @malloc(i64)
declare void @free(i8*)
declare double @sin(double)

; A store of a constant must not hide the later store of an active value.
define double @constant_then_active_store(double %x) {
entry:
  %a = alloca double, align 8
  store double 1.000000e+00, double* %a, align 8
  %first = load double, double* %a, align 8
  store double %x, double* %a, align 8
  %second = load double, double* %a, align 8
  ret double %second
}

; Only constants are stored, so the slot and what is loaded from it stay inactive.
define double @only_constant_stores(double %x) {
entry:
  %a = alloca double, align 8
  store double 1.000000e+00, double* %a, align 8
  store double 2.000000e+00, double* %a, align 8
  %first = load double, double* %a, align 8
  %r = fmul double %first, %x
  ret double %r
}

; The active store sits before the allocation in its own block, so a search of
; what can follow the allocation reaches it only through the back edge.
define double @store_before_allocation_in_loop(double %x, i64 %n) {
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %prev = phi double* [ null, %entry ], [ %cur, %loop ]
  %isfirst = icmp eq i64 %i, 0
  %slot = select i1 %isfirst, double* @scratch, double* %prev
  store double %x, double* %slot, align 8
  %m = call noalias i8* @malloc(i64 8)
  %cur = bitcast i8* %m to double*
  %v = load double, double* %cur, align 8
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop

exit:
  ret double %v
}

@scratch = private global double 0.000000e+00

; A store in a block that ends in unreachable is not part of the search.
define double @store_on_unreachable_path(double %x, i1 %c) {
entry:
  %a = alloca double, align 8
  store double 1.000000e+00, double* %a, align 8
  br i1 %c, label %bad, label %ok

bad:
  store double %x, double* %a, align 8
  unreachable

ok:
  %l = load double, double* %a, align 8
  %r = fmul double %l, %x
  ret double %r
}

; Calls that only free memory or compute a libm function do not count as stores.
define double @calls_that_do_not_store(double %x) {
entry:
  %m = call noalias i8* @malloc(i64 8)
  %p = bitcast i8* %m to double*
  store double 1.000000e+00, double* %p, align 8
  %s = call double @sin(double %x)
  %l = load double, double* %p, align 8
  call void @free(i8* %m)
  %r = fmul double %l, %s
  ret double %r
}

; A known-inactive atomic load is not skipped, whatever its ordering: the
; ordered load still counts as an access of the slot.
define double @ordered_load_of_known_integer(double %x) {
entry:
  %a = alloca i64, align 8
  %i = load atomic i64, i64* %a monotonic, align 8
  %b = bitcast i64* %a to double*
  store double %x, double* %b, align 8
  %l = load double, double* %b, align 8
  ret double %l
}

; CONSTANT-THEN-ACTIVE-STORE: double %x: icv:0
; CONSTANT-THEN-ACTIVE-STORE-NEXT: entry
; CONSTANT-THEN-ACTIVE-STORE-NEXT:   %a = alloca double, align 8: icv:0 ici:1
; CONSTANT-THEN-ACTIVE-STORE-NEXT:   store double 1.000000e+00, double* %a, align 8: icv:1 ici:1
; CONSTANT-THEN-ACTIVE-STORE-NEXT:   %first = load double, double* %a, align 8: icv:1 ici:1
; CONSTANT-THEN-ACTIVE-STORE-NEXT:   store double %x, double* %a, align 8: icv:1 ici:0
; CONSTANT-THEN-ACTIVE-STORE-NEXT:   %second = load double, double* %a, align 8: icv:0 ici:0
; CONSTANT-THEN-ACTIVE-STORE-NEXT:   ret double %second: icv:1 ici:1

; ONLY-CONSTANT-STORES: double %x: icv:0
; ONLY-CONSTANT-STORES-NEXT: entry
; ONLY-CONSTANT-STORES-NEXT:   %a = alloca double, align 8: icv:1 ici:1
; ONLY-CONSTANT-STORES-NEXT:   store double 1.000000e+00, double* %a, align 8: icv:1 ici:1
; ONLY-CONSTANT-STORES-NEXT:   store double 2.000000e+00, double* %a, align 8: icv:1 ici:1
; ONLY-CONSTANT-STORES-NEXT:   %first = load double, double* %a, align 8: icv:1 ici:1
; ONLY-CONSTANT-STORES-NEXT:   %r = fmul double %first, %x: icv:0 ici:0
; ONLY-CONSTANT-STORES-NEXT:   ret double %r: icv:1 ici:1

; STORE-BEFORE-ALLOCATION-IN-LOOP: double %x: icv:0
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT: i64 %n: icv:1
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT: entry
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT:   br label %loop: icv:1 ici:1
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT: loop
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT:   %i = phi i64 [ 0, %entry ], [ %next, %loop ]: icv:1 ici:1
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT:   %prev = phi double* [ null, %entry ], [ %cur, %loop ]: icv:0 ici:1
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT:   %isfirst = icmp eq i64 %i, 0: icv:1 ici:1
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT:   %slot = select i1 %isfirst, double* @scratch, double* %prev: icv:0 ici:1
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT:   store double %x, double* %slot, align 8: icv:1 ici:0
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT:   %m = call noalias i8* @malloc(i64 8): icv:0 ici:1
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT:   %cur = bitcast i8* %m to double*: icv:0 ici:1
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT:   %v = load double, double* %cur, align 8: icv:0 ici:0
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT:   %next = add i64 %i, 1: icv:1 ici:1
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT:   %done = icmp eq i64 %next, %n: icv:1 ici:1
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT:   br i1 %done, label %exit, label %loop: icv:1 ici:1
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT: exit
; STORE-BEFORE-ALLOCATION-IN-LOOP-NEXT:   ret double %v: icv:1 ici:1

; STORE-ON-UNREACHABLE-PATH: double %x: icv:0
; STORE-ON-UNREACHABLE-PATH-NEXT: i1 %c: icv:1
; STORE-ON-UNREACHABLE-PATH-NEXT: entry
; STORE-ON-UNREACHABLE-PATH-NEXT:   %a = alloca double, align 8: icv:1 ici:1
; STORE-ON-UNREACHABLE-PATH-NEXT:   store double 1.000000e+00, double* %a, align 8: icv:1 ici:1
; STORE-ON-UNREACHABLE-PATH-NEXT:   br i1 %c, label %bad, label %ok: icv:1 ici:1
; STORE-ON-UNREACHABLE-PATH-NEXT: bad
; STORE-ON-UNREACHABLE-PATH-NEXT:   store double %x, double* %a, align 8: icv:1 ici:1
; STORE-ON-UNREACHABLE-PATH-NEXT:   unreachable: icv:1 ici:1
; STORE-ON-UNREACHABLE-PATH-NEXT: ok
; STORE-ON-UNREACHABLE-PATH-NEXT:   %l = load double, double* %a, align 8: icv:1 ici:1
; STORE-ON-UNREACHABLE-PATH-NEXT:   %r = fmul double %l, %x: icv:0 ici:0
; STORE-ON-UNREACHABLE-PATH-NEXT:   ret double %r: icv:1 ici:1

; CALLS-THAT-DO-NOT-STORE: double %x: icv:0
; CALLS-THAT-DO-NOT-STORE-NEXT: entry
; CALLS-THAT-DO-NOT-STORE-NEXT:   %m = call noalias i8* @malloc(i64 8): icv:1 ici:1
; CALLS-THAT-DO-NOT-STORE-NEXT:   %p = bitcast i8* %m to double*: icv:1 ici:1
; CALLS-THAT-DO-NOT-STORE-NEXT:   store double 1.000000e+00, double* %p, align 8: icv:1 ici:1
; CALLS-THAT-DO-NOT-STORE-NEXT:   %s = call double @sin(double %x): icv:0 ici:0
; CALLS-THAT-DO-NOT-STORE-NEXT:   %l = load double, double* %p, align 8: icv:1 ici:1
; CALLS-THAT-DO-NOT-STORE-NEXT:   call void @free(i8* %m): icv:1 ici:1
; CALLS-THAT-DO-NOT-STORE-NEXT:   %r = fmul double %l, %s: icv:0 ici:0
; CALLS-THAT-DO-NOT-STORE-NEXT:   ret double %r: icv:1 ici:1

; ORDERED-LOAD-OF-KNOWN-INTEGER: double %x: icv:0
; ORDERED-LOAD-OF-KNOWN-INTEGER-NEXT: entry
; ORDERED-LOAD-OF-KNOWN-INTEGER-NEXT:   %a = alloca i64, align 8: icv:0 ici:1
; ORDERED-LOAD-OF-KNOWN-INTEGER-NEXT:   %i = load atomic i64, i64* %a monotonic, align 8: icv:1 ici:0
; ORDERED-LOAD-OF-KNOWN-INTEGER-NEXT:   %b = bitcast i64* %a to double*: icv:0 ici:1
; ORDERED-LOAD-OF-KNOWN-INTEGER-NEXT:   store double %x, double* %b, align 8: icv:1 ici:0
; ORDERED-LOAD-OF-KNOWN-INTEGER-NEXT:   %l = load double, double* %b, align 8: icv:0 ici:0
; ORDERED-LOAD-OF-KNOWN-INTEGER-NEXT:   ret double %l: icv:1 ici:1
