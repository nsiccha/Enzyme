; RUN: %opt < %s %newLoadEnzyme -passes="print-type-analysis" -type-analysis-func=taped -S | FileCheck %s --check-prefix=TAPED
; RUN: %opt < %s %newLoadEnzyme -passes="print-type-analysis" -type-analysis-func=untaped -S | FileCheck %s --check-prefix=UNTAPED
; RUN: %opt < %s %newLoadEnzyme -passes="print-type-analysis" -type-analysis-func=reinterpreted -S | FileCheck %s --check-prefix=BITS

; RUN: %opt < %s %newLoadEnzyme -passes="print-type-analysis" -type-analysis-func=checked -S | FileCheck %s --check-prefix=CHECKED

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

define {i64, double} @taped(double* %data, i1 %flag, i64 %base) {
  %correction = zext i1 %flag to i64
  %index = add i64 %base, %correction, !enzyme_taped_index !0
  %address = getelementptr inbounds double, double* %data, i64 %index
  %entry = load double, double* %address
  %tape = insertvalue {i64, double} undef, i64 %index, 0
  %result = insertvalue {i64, double} %tape, double %entry, 1
  ret {i64, double} %result
}
; TAPED: %correction = zext i1 %flag to i64: {[-1]:Integer}

define {i64, double} @untaped(double* %data, i1 %flag, i64 %base) {
  %correction = zext i1 %flag to i64
  %index = add i64 %base, %correction
  %address = getelementptr inbounds double, double* %data, i64 %index
  %entry = load double, double* %address
  %tape = insertvalue {i64, double} undef, i64 %index, 0
  %result = insertvalue {i64, double} %tape, double %entry, 1
  ret {i64, double} %result
}
; UNTAPED: %correction = zext i1 %flag to i64: {[-1]:Anything}

define {i64, double} @reinterpreted(i1 %flag, i64 %base) {
  %correction = zext i1 %flag to i64
  %index = add i64 %base, %correction, !enzyme_taped_index !0
  %bits = bitcast i64 %index to double
  %tape = insertvalue {i64, double} undef, i64 %index, 0
  %result = insertvalue {i64, double} %tape, double %bits, 1
  ret {i64, double} %result
}
; BITS: %correction = zext i1 %flag to i64: {[-1]:Anything}

define {i64, double} @checked(double* %data, i64* %escaped, i1 %flag, i64 %base, i64 %length) {
  %correction = zext i1 %flag to i64
  %row = add i64 %base, %correction
  store i64 %row, i64* %escaped
  %index = add i64 %row, -1, !enzyme_taped_index !0
  %inbounds = icmp ult i64 %index, %length
  %address = getelementptr inbounds double, double* %data, i64 %index
  %entry = load double, double* %address
  %value = select i1 %inbounds, double %entry, double 0.0
  %tape = insertvalue {i64, double} undef, i64 %index, 0
  %result = insertvalue {i64, double} %tape, double %value, 1
  ret {i64, double} %result
}

; CHECKED: %correction = zext i1 %flag to i64: {[-1]:Anything}
; CHECKED: %result = insertvalue {{.*}}: {[0]:Integer, {{.*}}[7]:Integer

!0 = !{}
