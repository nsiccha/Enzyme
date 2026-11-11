; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -print-type-analysis -type-analysis-func=caller -o /dev/null | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -passes="print-type-analysis" -type-analysis-func=caller -S -o /dev/null | FileCheck %s

; A global that type analysis must not recurse into (the Julia frontend's
; jl_nothing, its undefined value for a GC-tracked pointer) seeds two cache
; slots of one pointer type through one constant expression, which LLVM
; uniques. What each slot holds (pointers to doubles, pointers to integers)
; must stay with its own phi and never meet on that shared constant.

@jl_nothing = external addrspace(10) global {}, !enzyme_ta_norecur !0

define void @caller(i8* addrspace(11)* %fcache, i8* addrspace(11)* %icache, double* %fout, double* %iout, i1 %entered) {
entry:
  br i1 %entered, label %loop, label %merge

loop:
  br label %merge

merge:
  %fslot = phi i8* addrspace(11)* [ addrspacecast ({} addrspace(10)* @jl_nothing to i8* addrspace(11)*), %entry ], [ %fcache, %loop ]
  %islot = phi i8* addrspace(11)* [ addrspacecast ({} addrspace(10)* @jl_nothing to i8* addrspace(11)*), %entry ], [ %icache, %loop ]
  %fp8 = load i8*, i8* addrspace(11)* %fslot, align 8
  %fp = bitcast i8* %fp8 to double*
  %f = load double, double* %fp, align 8
  %f2 = fadd double %f, 1.000000e+00
  store double %f2, double* %fout, align 8
  %ip8 = load i8*, i8* addrspace(11)* %islot, align 8
  %ip = bitcast i8* %ip8 to i64*
  %i = load i64, i64* %ip, align 8
  %i2 = sitofp i64 %i to double
  store double %i2, double* %iout, align 8
  ret void
}

!0 = !{}

; CHECK: caller - {} |
; CHECK: {{^merge$}}
; CHECK-NEXT:   %fslot = phi {{.*}}@jl_nothing{{.*}}: {[-1]:Pointer, [-1,0]:Pointer, [-1,0,0]:Float@double}
; CHECK-NEXT:   %islot = phi {{.*}}@jl_nothing{{.*}}: {[-1]:Pointer, [-1,0]:Pointer, [-1,0,0]:Integer, [-1,0,1]:Integer, [-1,0,2]:Integer, [-1,0,3]:Integer, [-1,0,4]:Integer, [-1,0,5]:Integer, [-1,0,6]:Integer, [-1,0,7]:Integer}
