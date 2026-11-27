; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -enzyme-preopt=false -S | FileCheck %s; fi
; RUN: if [ %llvmver -lt 17 ]; then %opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-preopt=false -S | FileCheck %s; fi

; A frontend marks the call that initialises an allocation's reference slots
; with "enzyme_math"="enzyme_zerotype" (Julia does for a stack slot Enzyme
; moves to its garbage-collected heap). Only a number is loaded back from this
; record, so its shadow is created in the reverse pass, and the forward pass
; must not zero that shadow. The call on the record itself has to stay in the
; forward pass all the same: the primal never writes the reference slot, and a
; collector that scans the record would follow whatever the allocator left
; there.

declare noalias i8* @malloc(i64)

define internal void @zero_record(i8* nocapture writeonly %p, i8 %unused, i64 %size) #0 {
entry:
  %slot = bitcast i8* %p to i8**
  store i8* null, i8** %slot, align 8
  ret void
}

define double @callee(double %x) {
entry:
  %m = call noalias i8* @malloc(i64 16)
  call void @zero_record(i8* %m, i8 0, i64 16)
  %rec = bitcast i8* %m to { i8*, double }*
  %num = getelementptr inbounds { i8*, double }, { i8*, double }* %rec, i64 0, i32 1
  store double %x, double* %num, align 8
  %ld = load double, double* %num, align 8
  %sq = fmul double %ld, %ld
  ret double %sq
}

define double @outer(double %x) {
entry:
  %m = call double @callee(double %x)
  %r = fmul double %m, %x
  ret double %r
}

declare double @__enzyme_autodiff(i8*, double)

define double @test(double %x) {
entry:
  %r = call double @__enzyme_autodiff(i8* bitcast (double (double)* @outer to i8*), double %x)
  ret double %r
}

attributes #0 = { noinline nounwind "enzyme_math"="enzyme_zerotype" }

; The forward pass zeroes the record and nothing else.
; CHECK: define internal double @augmented_callee(double %x)
; CHECK: %m = call noalias i8* @malloc(i64 16)
; CHECK-NEXT: call void @zero_record(i8* %m, i8 0, i64 16)
; CHECK-NEXT: %rec = bitcast i8* %m to { i8*, double }*
; CHECK-NOT: @zero_record
; CHECK: ret double

; The reverse pass creates the shadow and zeroes it.
; CHECK: define internal { double } @diffecallee(double %x, double %differeturn)
; CHECK: %"m'mi" = call noalias nonnull dereferenceable(16) dereferenceable_or_null(16) i8* @malloc(i64 16)
; CHECK: call void @zero_record(i8* %"m'mi", i8 0, i64 16)
