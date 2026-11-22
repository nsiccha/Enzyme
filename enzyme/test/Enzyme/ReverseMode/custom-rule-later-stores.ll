; REQUIRES: enzyme_test_plugin
; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme %loadTestCallHandler -enzyme-preopt=false -passes="enzyme,verify" -disable-output 2>&1 | FileCheck %s; fi

; A custom rule sees the individual local store in each caller. The opaque
; call after the second store must still count as an unclassified write.
; CHECK-DAG: local store to first_slot, unclassified writes 0
; CHECK-DAG: local store to second_slot, unclassified writes 1

@first_slot = global ptr null
@second_slot = global ptr null
@marker = global i32 0

define double @__enzyme_test_report_stores(double %x) noinline {
  store volatile i32 1, ptr @marker
  ret double %x
}

declare void @opaque() "enzyme_inactive"

define double @local(double %x, ptr %value) {
  %y = call double @__enzyme_test_report_stores(double %x)
  store volatile ptr %value, ptr @first_slot
  ret double %y
}

define double @mixed(double %x, ptr %value) {
  %y = call double @__enzyme_test_report_stores(double %x)
  store volatile ptr %value, ptr @second_slot
  call void @opaque()
  ret double %y
}

declare double @__enzyme_autodiff(...)

define void @run(double %x, ptr %value) {
  call double (...) @__enzyme_autodiff(ptr @local, double %x, metadata !"enzyme_const", ptr %value)
  call double (...) @__enzyme_autodiff(ptr @mixed, double %x, metadata !"enzyme_const", ptr %value)
  ret void
}
