; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -enzyme-preopt=false -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -passes="enzyme" -enzyme-preopt=false -S | FileCheck %s

; The length is overwritten, so the reverse pass reads it from the tape. The
; read keeps the type the analysis of the primal found, so that a forward pass
; over this reverse pass does not have to guess what the tape holds.

define double @tester(double* %x, i64* %n) {
entry:
  %len = load i64, i64* %n, align 8, !tbaa !0
  store i64 0, i64* %n, align 8, !tbaa !0
  %first = xor i64 %len, 1
  %second = xor i64 %len, 2
  %p = getelementptr inbounds double, double* %x, i64 %first
  %q = getelementptr inbounds double, double* %x, i64 %second
  %v = load double, double* %p, align 8, !tbaa !4
  %w = load double, double* %q, align 8, !tbaa !4
  %m = fmul double %v, %w
  ret double %m
}

define void @reverse(double* %x, double* %dx, i64* %n, i8* %cache) {
entry:
  call void (double (double*, i64*)*, ...) @__enzyme_reverse(double (double*, i64*)* nonnull @tester, metadata !"enzyme_allocated", i64 64, metadata !"enzyme_tape", i8* %cache, double* %x, double* %dx, metadata !"enzyme_const", i64* %n, double 1.0)
  ret void
}

declare void @__enzyme_reverse(double (double*, i64*)*, ...)

!0 = !{!1, !1, i64 0}
!1 = !{!"long", !2, i64 0}
!2 = !{!"omnipotent char", !3, i64 0}
!3 = !{!"Simple C/C++ TBAA"}
!4 = !{!5, !5, i64 0}
!5 = !{!"double", !2, i64 0}

; CHECK: define internal void @diffetester(
; CHECK: %len = extractvalue { i64, double, double } %tapeArg, 0, !enzyme_type ![[INT:[0-9]+]]
; CHECK: %v = extractvalue { i64, double, double } %tapeArg, 1, !enzyme_type ![[FLT:[0-9]+]]
; CHECK: %w = extractvalue { i64, double, double } %tapeArg, 2, !enzyme_type ![[FLT]]
; CHECK-DAG: ![[INT]] = !{!"Unknown", i32 -1, ![[INTD:[0-9]+]]}
; CHECK-DAG: ![[INTD]] = !{!"Integer"}
; CHECK-DAG: ![[FLT]] = !{!"Unknown", i32 -1, ![[FLTD:[0-9]+]]}
; CHECK-DAG: ![[FLTD]] = !{!"Float@double"}
