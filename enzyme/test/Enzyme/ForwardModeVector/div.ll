; RUN: if [ %llvmver -lt 16 ]; then %opt < %s %loadEnzyme -enzyme -enzyme-preopt=false -mem2reg -early-cse -instsimplify -simplifycfg -S | FileCheck %s; fi
; RUN: %opt < %s %newLoadEnzyme -passes="enzyme,function(mem2reg,early-cse,instsimplify,%simplifycfg)" -enzyme-preopt=false -S | FileCheck %s

%struct.Gradients = type { double, double }

; Function Attrs: nounwind
declare %struct.Gradients @__enzyme_fwddiff(double (double,double)*, ...)

; Function Attrs: noinline nounwind readnone uwtable
define double @tester(double %x, double %y) {
entry:
  %0 = fdiv fast double %x, %y
  ret double %0
}

define %struct.Gradients @test_derivative(double %x, double %y) {
entry:
  %0 = tail call %struct.Gradients (double (double, double)*, ...) @__enzyme_fwddiff(double (double, double)* nonnull @tester, metadata !"enzyme_width", i64 2, double %x, double 0.0, double 1.0, double %y, double 1.0, double 0.0)
  ret %struct.Gradients %0
}


; CHECK: define internal [2 x double] @fwddiffe2tester(double %x, [2 x double] %"x'", double %y, [2 x double] %"y'")
; CHECK-NEXT: entry:
; CHECK-NEXT:   %[[i0:.+]] = extractvalue [2 x double] %"y'", 0
; CHECK-NEXT:   %[[i1:.+]] = fdiv fast double %[[i0]], %y
; CHECK-NEXT:   %[[i2:.+]] = extractvalue [2 x double] %"y'", 1
; CHECK-NEXT:   %[[i3:.+]] = fdiv fast double %[[i2]], %y
; CHECK-NEXT:   %[[i4:.+]] = fmul fast double %[[i1]], %x
; CHECK-NEXT:   %[[i5:.+]] = fmul fast double %[[i3]], %x
; CHECK-NEXT:   %[[i6:.+]] = extractvalue [2 x double] %"x'", 0
; CHECK-NEXT:   %[[i7:.+]] = fsub fast double %[[i6]], %[[i4]]
; CHECK-NEXT:   %[[i8:.+]] = extractvalue [2 x double] %"x'", 1
; CHECK-NEXT:   %[[i9:.+]] = fsub fast double %[[i8]], %[[i5]]
; CHECK-NEXT:   %[[i10:.+]] = fdiv fast double %[[i7]], %y
; CHECK-NEXT:   %[[i11:.+]] = insertvalue [2 x double] undef, double %[[i10]], 0
; CHECK-NEXT:   %[[i12:.+]] = fdiv fast double %[[i9]], %y
; CHECK-NEXT:   %[[i13:.+]] = insertvalue [2 x double] %[[i11]], double %[[i12]], 1
; CHECK-NEXT:   ret [2 x double] %[[i13]]
; CHECK-NEXT: }
