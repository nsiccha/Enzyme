; RUN: if [ %llvmver -ge 15 ]; then %opt < %s %OPnewLoadEnzyme -passes="enzyme" -enzyme-preopt=false -S | %lli -; fi

; Two sibling loops read the same row before a later write forces the values
; to be cached. Reusing the first loop's cache is valid only when its index is
; replaced by the second loop's current reverse index.

@enzyme_const = external global i32
@x = internal global [5 x double] [double 2.0, double 0.0, double -3.0, double 0.0, double 5.0]
@b = internal global [3 x double] [double 1.0, double 2.0, double 3.0]
@c = internal global [3 x double] [double 4.0, double 5.0, double 6.0]
@db = internal global [3 x double] zeroinitializer
@dc = internal global [3 x double] zeroinitializer

define double @f(ptr %x, ptr %b, ptr %c, i64 %n, i64 %stride) noinline {
entry:
  br label %first
first:
  %i = phi i64 [0, %entry], [%inext, %first]
  %asum = phi double [0.0, %entry], [%anext, %first]
  %xi = mul i64 %i, %stride
  %xp = getelementptr inbounds double, ptr %x, i64 %xi
  %a = load double, ptr %xp, align 8
  %bp = getelementptr inbounds double, ptr %b, i64 %i
  %bv = load double, ptr %bp, align 8
  %aprod = fmul double %a, %bv
  %anext = fadd double %asum, %aprod
  %inext = add nuw nsw i64 %i, 1
  %idone = icmp eq i64 %inext, %n
  br i1 %idone, label %middle, label %first
middle:
  %sum1 = phi double [%anext, %first]
  br label %second
second:
  %j = phi i64 [0, %middle], [%jnext, %second]
  %csum = phi double [0.0, %middle], [%cnext, %second]
  %xj = mul i64 %j, %stride
  %xq = getelementptr inbounds double, ptr %x, i64 %xj
  %a2 = load double, ptr %xq, align 8
  %cp = getelementptr inbounds double, ptr %c, i64 %j
  %cv = load double, ptr %cp, align 8
  %cprod = fmul double %a2, %cv
  %cnext = fadd double %csum, %cprod
  %jnext = add nuw nsw i64 %j, 1
  %jdone = icmp eq i64 %jnext, %n
  br i1 %jdone, label %exit, label %second
exit:
  %sum2 = phi double [%cnext, %second]
  store double 0.0, ptr %x, align 8
  %result = fmul double %sum1, %sum2
  ret double %result
}

declare void @__enzyme_autodiff(...)

define i32 @main() {
entry:
  call void (...) @__enzyme_autodiff(ptr @f, ptr @enzyme_const, ptr @x, ptr @b, ptr @db, ptr @c, ptr @dc, i64 3, i64 2)
  %b0 = load double, ptr @db, align 8
  %b1 = load double, ptr getelementptr inbounds ([3 x double], ptr @db, i64 0, i64 1), align 8
  %b2 = load double, ptr getelementptr inbounds ([3 x double], ptr @db, i64 0, i64 2), align 8
  %c0 = load double, ptr @dc, align 8
  %c1 = load double, ptr getelementptr inbounds ([3 x double], ptr @dc, i64 0, i64 1), align 8
  %c2 = load double, ptr getelementptr inbounds ([3 x double], ptr @dc, i64 0, i64 2), align 8
  %ok0 = fcmp oeq double %b0, 46.0
  %ok1 = fcmp oeq double %b1, -69.0
  %ok2 = fcmp oeq double %b2, 115.0
  %ok3 = fcmp oeq double %c0, 22.0
  %ok4 = fcmp oeq double %c1, -33.0
  %ok5 = fcmp oeq double %c2, 55.0
  %ok01 = and i1 %ok0, %ok1
  %ok23 = and i1 %ok2, %ok3
  %ok45 = and i1 %ok4, %ok5
  %ok0123 = and i1 %ok01, %ok23
  %ok = and i1 %ok0123, %ok45
  %code = select i1 %ok, i32 0, i32 1
  ret i32 %code
}
