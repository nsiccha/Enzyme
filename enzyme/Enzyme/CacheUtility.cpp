//===- CacheUtility.cpp - Caching values in the forward pass for later use
//-===//
//
//                             Enzyme Project
//
// Part of the Enzyme Project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
// If using this code in an academic setting, please cite the following:
// @incollection{enzymeNeurips,
// title = {Instead of Rewriting Foreign Code for Machine Learning,
//          Automatically Synthesize Fast Gradients},
// author = {Moses, William S. and Churavy, Valentin},
// booktitle = {Advances in Neural Information Processing Systems 33},
// year = {2020},
// note = {To appear in},
// }
//
//===----------------------------------------------------------------------===//
//
// This file defines a base helper class CacheUtility that manages the cache
// of values from the forward pass for later use.
//
//===----------------------------------------------------------------------===//

#include "CacheUtility.h"

#include "llvm/IR/PatternMatch.h"

#include "FunctionUtils.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include <utility>

using namespace llvm;

/// Pack 8 bools together in a single byte
extern "C" {
llvm::cl::opt<bool>
    EfficientBoolCache("enzyme-smallbool", cl::init(false), cl::Hidden,
                       cl::desc("Place 8 bools together in a single byte"));

llvm::cl::opt<bool> EnzymeZeroCache("enzyme-zero-cache", cl::init(false),
                                    cl::Hidden,
                                    cl::desc("Zero initialize the cache"));

llvm::cl::opt<bool>
    EnzymePrintPerf("enzyme-print-perf", cl::init(false), cl::Hidden,
                    cl::desc("Enable Enzyme to print performance info"));

llvm::cl::opt<bool> EfficientMaxCache(
    "enzyme-max-cache", cl::init(false), cl::Hidden,
    cl::desc(
        "Avoid reallocs when possible by potentially overallocating cache"));

llvm::cl::opt<bool> EnzymeRewriteAccumulators(
    "enzyme-rewrite-accumulators", cl::init(true), cl::Hidden,
    cl::desc("Rewrite a loop-carried counter whose step is an inner loop's "
             "trip count into a closed form of the induction variable"));

// The tape arena is off by default, so that the tests of the caches it replaces keep
// their allocations; a frontend turns both options on (Enzyme.jl does).
llvm::cl::opt<bool> EnzymeCallerOwnedTapes(
    "enzyme-caller-owned-tapes", cl::init(false), cl::Hidden,
    cl::desc("Store non-inlined callees' pointer-free loop caches in the caller"));

llvm::cl::opt<bool> EnzymeArenaCombinedCaches(
    "enzyme-arena-combined-caches", cl::init(false), cl::Hidden,
    cl::desc("Reserve a combined derivative's bounded loop caches from its "
             "tape arena, released at its return, instead of one malloc and "
             "free each"));

llvm::cl::opt<bool> EnzymeGroupPackedCaches(
    "enzyme-group-packed-caches", cl::init(true), cl::Hidden,
    cl::desc("Store the packed ragged caches of one element type and loop "
             "nest of a combined derivative as records of one buffer, with "
             "one offset table, instead of one table and buffer per cache"));
}

CacheUtility::~CacheUtility() {}

// Raw buffers can move when a chunk grows. Reject types that need GC or
// pointer fixups, and types whose stride is unknown or zero.
static bool isPackedElement(Type *T) {
  if (T->isIntegerTy() || T->isFloatingPointTy())
    return true;
  if (auto *V = dyn_cast<FixedVectorType>(T))
    return isPackedElement(V->getElementType());
  if (auto *A = dyn_cast<ArrayType>(T))
    return isPackedElement(A->getElementType());
  if (auto *S = dyn_cast<StructType>(T))
    return !S->isOpaque() && llvm::all_of(S->elements(), isPackedElement);
  return false;
}

bool isCallerOwnedCacheElement(Type *T) {
  if (auto *I = dyn_cast<IntegerType>(T))
    return I->getBitWidth() <= 64;
  return isPackedElement(T);
}

bool canUseCallerTapeArena(const Module &M) {
  auto arch = Triple(M.getTargetTriple()).getArch();
  // A derivative compiled on behalf of another one (the inner derivative of
  // a nested one) is differentiated again with the module it is linked into,
  // and an outer derivative cannot differentiate through the arena's single
  // release of all its chunks; such a module keeps one malloc per cache.
  return EnzymeCallerOwnedTapes &&
         !M.getModuleFlag("enzyme_no_tape_arena") &&
         (arch == Triple::x86_64 || arch == Triple::aarch64) &&
         M.getDataLayout().getPointerSizeInBits() == 64 &&
         M.getDataLayout().getAllocaAddrSpace() == 0;
}

// Each augmented call returns its slice pointer in its usual tape field. A
// new chunk links to the previous one so growing never invalidates a tape.
StructType *getCallerTapeArenaType(LLVMContext &C) {
  auto i64 = Type::getInt64Ty(C);
  return StructType::get(C, {getInt8PtrTy(C), i64, i64});
}

Function *getCallerTapeReserve(Module &M) {
  auto &C = M.getContext();
  auto arenaTy = getCallerTapeArenaType(C);
  auto ptrTy = getInt8PtrTy(C);
  auto i64 = Type::getInt64Ty(C);
  auto reserve =
      cast<Function>(M.getOrInsertFunction("__enzyme_caller_tape_reserve",
                                           ptrTy, getUnqual(arenaTy), i64)
                         .getCallee());
  if (!reserve->empty())
    return reserve;
  reserve->setLinkage(Function::InternalLinkage);
  reserve->addFnAttr(Attribute::NoUnwind);
  // A slice is fresh memory like malloc's: it aliases nothing the caller can
  // reach, and a reservation touches only the arena and the allocator. Keep
  // the call, so optimizations of the derivative see these facts.
  reserve->addFnAttr(Attribute::NoInline);
  reserve->addRetAttr(Attribute::NoAlias);
  reserve->addRetAttr(Attribute::NonNull);
#if LLVM_VERSION_MAJOR >= 16
  reserve->setOnlyAccessesInaccessibleMemOrArgMem();
#else
  reserve->addFnAttr(Attribute::InaccessibleMemOrArgMemOnly);
#endif
  // Chunks double from 256 bytes up to 64 KiB, so a derivative makes a few
  // allocations for many small caches and holds at most one partly used
  // chunk beyond what it stores. A request above 4 KiB gets a chunk of its
  // own size, linked behind the current one, so a large cache costs one
  // allocation of exactly its size, as before, and never doubles the next.
  constexpr uint64_t firstChunk = 256;
  constexpr uint64_t largestChunk = 64 * 1024;
  constexpr uint64_t largeRequest = 4 * 1024;
  auto entry = BasicBlock::Create(C, "entry", reserve);
  auto fit = BasicBlock::Create(C, "check.capacity", reserve);
  auto choose = BasicBlock::Create(C, "choose", reserve);
  auto large = BasicBlock::Create(C, "large", reserve);
  auto largeLink = BasicBlock::Create(C, "large.link", reserve);
  auto grow = BasicBlock::Create(C, "grow", reserve);
  auto link = BasicBlock::Create(C, "link", reserve);
  auto done = BasicBlock::Create(C, "slice", reserve);
  auto fail = BasicBlock::Create(C, "failed", reserve);
  IRBuilder<> B(entry);
  auto arena = reserve->getArg(0);
  auto bytes = reserve->getArg(1);
  // Space for the link and alignment of the next payload. Keep zero-length
  // requests distinct, as the original allocation may be marked nonnull.
  constexpr uint64_t alignment = 16;
  constexpr uint64_t maxCapacity = UINT64_MAX - (2 * alignment - 1);
  B.CreateCondBr(B.CreateICmpULE(bytes, B.getInt64(maxCapacity)), fit, fail);
  B.SetInsertPoint(fit);
  auto rounded = B.CreateAnd(B.CreateAdd(bytes, B.getInt64(alignment - 1)),
                             B.getInt64(~(alignment - 1)));
  auto need =
      B.CreateSelect(B.CreateIsNull(bytes), B.getInt64(alignment), rounded);
  auto headAddr = B.CreateStructGEP(arenaTy, arena, 0);
  auto usedAddr = B.CreateStructGEP(arenaTy, arena, 1);
  auto capacityAddr = B.CreateStructGEP(arenaTy, arena, 2);
  auto head = B.CreateLoad(ptrTy, headAddr);
  auto used = B.CreateLoad(i64, usedAddr);
  auto capacity = B.CreateLoad(i64, capacityAddr);
  B.CreateCondBr(B.CreateICmpULE(need, B.CreateSub(capacity, used)), done,
                 choose);

  B.SetInsertPoint(choose);
  auto alloc = M.getOrInsertFunction("malloc", ptrTy, i64);
  B.CreateCondBr(B.CreateAnd(B.CreateICmpUGT(need, B.getInt64(largeRequest)),
                             B.CreateIsNotNull(head)),
                 large, grow);

  B.SetInsertPoint(large);
  auto own = B.CreateCall(alloc, {B.CreateAdd(need, B.getInt64(alignment))});
  own->addRetAttr(Attribute::NoAlias);
  B.CreateCondBr(B.CreateIsNull(own), fail, largeLink);

  B.SetInsertPoint(largeLink);
  auto headLink = B.CreatePointerCast(head, getUnqual(ptrTy));
  B.CreateStore(B.CreateLoad(ptrTy, headLink),
                B.CreatePointerCast(own, getUnqual(ptrTy)));
  B.CreateStore(own, headLink);
  B.CreateRet(B.CreateInBoundsGEP(B.getInt8Ty(), own, B.getInt64(alignment)));

  B.SetInsertPoint(grow);
  auto bounded = B.CreateShl(
      B.CreateSelect(B.CreateICmpULT(capacity, B.getInt64(largestChunk / 2)),
                     capacity, B.getInt64(largestChunk / 2)),
      1);
  auto atLeastFirst =
      B.CreateSelect(B.CreateICmpULT(bounded, B.getInt64(firstChunk)),
                     B.getInt64(firstChunk), bounded);
  auto newCapacity = B.CreateSelect(B.CreateICmpUGT(need, atLeastFirst), need,
                                    atLeastFirst);
  auto newHead =
      B.CreateCall(alloc, {B.CreateAdd(newCapacity, B.getInt64(alignment))});
  newHead->addRetAttr(Attribute::NoAlias);
  B.CreateCondBr(B.CreateIsNull(newHead), fail, link);

  B.SetInsertPoint(link);
  B.CreateStore(head, B.CreatePointerCast(newHead, getUnqual(ptrTy)));
  B.CreateStore(newHead, headAddr);
  B.CreateStore(newCapacity, capacityAddr);
  B.CreateBr(done);

  B.SetInsertPoint(done);
  auto chunk = B.CreatePHI(ptrTy, 2);
  chunk->addIncoming(head, fit);
  chunk->addIncoming(newHead, link);
  auto offset = B.CreatePHI(i64, 2);
  offset->addIncoming(used, fit);
  offset->addIncoming(B.getInt64(0), link);
  B.CreateStore(B.CreateAdd(offset, need), usedAddr);
  B.CreateRet(B.CreateInBoundsGEP(B.getInt8Ty(), chunk,
                                  B.CreateAdd(B.getInt64(alignment), offset)));
  B.SetInsertPoint(fail);
  B.CreateCall(getIntrinsicDeclaration(&M, Intrinsic::trap));
  B.CreateUnreachable();
  return reserve;
}

Function *getCallerTapeRelease(Module &M) {
  auto &C = M.getContext();
  auto arenaTy = getCallerTapeArenaType(C);
  auto ptrTy = getInt8PtrTy(C);
  auto release = cast<Function>(
      M.getOrInsertFunction("__enzyme_caller_tape_release", Type::getVoidTy(C),
                            getUnqual(arenaTy))
          .getCallee());
  if (!release->empty())
    return release;
  release->setLinkage(Function::InternalLinkage);
  release->addFnAttr(Attribute::NoUnwind);
  // Releasing frees the chunks every slice lives in, memory the arena only
  // reaches through its head pointer, so the call keeps its unknown effects.
  release->addFnAttr(Attribute::NoInline);
  auto entry = BasicBlock::Create(C, "entry", release);
  auto check = BasicBlock::Create(C, "check", release);
  auto loop = BasicBlock::Create(C, "release", release);
  auto done = BasicBlock::Create(C, "done", release);
  IRBuilder<> B(entry);
  auto head =
      B.CreateLoad(ptrTy, B.CreateStructGEP(arenaTy, release->getArg(0), 0));
  B.CreateBr(check);
  B.SetInsertPoint(check);
  auto chunk = B.CreatePHI(ptrTy, 2);
  chunk->addIncoming(head, entry);
  B.CreateCondBr(B.CreateIsNull(chunk), done, loop);
  B.SetInsertPoint(loop);
  auto prev = B.CreateLoad(ptrTy, B.CreatePointerCast(chunk, getUnqual(ptrTy)));
  auto free = M.getOrInsertFunction("free", B.getVoidTy(), ptrTy);
  B.CreateCall(free, {chunk});
  chunk->addIncoming(prev, loop);
  B.CreateBr(check);
  B.SetInsertPoint(done);
  B.CreateRetVoid();
  return release;
}

// A rectangular chunk inside a varying outer loop can use an offset table and
// one growing value buffer. Keep the table's pointer type so split reverse can
// pass it through the existing tape protocol: entry zero owns the value buffer,
// and subsequent entries encode element offsets rather than movable pointers.
static bool canPackRaggedCache(Type *T,
                               const CacheUtility::SubLimitType &sublimits,
                               const Module &M) {
  auto Arch = llvm::Triple(M.getTargetTriple()).getArch();
  if (sublimits.size() < 2 || !isPackedElement(T) ||
      !M.getDataLayout().getTypeAllocSize(T) ||
      M.getDataLayout().getPointerSizeInBits() != 64 ||
      M.getDataLayout().isNonIntegralAddressSpace(0) || Arch == Triple::nvptx ||
      Arch == Triple::nvptx64)
    return false;
  for (const auto &chunk : sublimits) {
    if (!chunk.second.back().first.maxLimit)
      return false;
    for (const auto &loop : chunk.second)
      if (loop.first.offset)
        return false;
  }
  return true;
}

struct CacheLayout {
  // Innermost element first, then one more level of pointers for each chunk.
  SmallVector<Type *, 4> types;
  SmallVector<PointerType *, 4> mallocTypes;
  bool packed;
};

// Probe the allocator for the actual tape types. Creation and lookup must
// make the same choice, including when they are compiled in separate passes.
static CacheLayout getCacheLayout(Function &F, Type *T,
                                  const CacheUtility::SubLimitType &sublimits) {
  CacheLayout layout;
  layout.packed = canPackRaggedCache(T, sublimits, *F.getParent());
  layout.types.push_back(EfficientBoolCache && T->isIntegerTy(1) &&
                                 !sublimits.empty()
                             ? Type::getInt8Ty(T->getContext())
                             : T);
  if (sublimits.empty())
    return layout;
  auto block = BasicBlock::Create(F.getContext(), "entry", &F);
  IRBuilder<> B(block);
  auto count = B.CreatePHI(B.getInt64Ty(), 1);
  for (size_t i = 0; i < sublimits.size(); ++i) {
    CallInst *call;
    Instruction *zero;
    auto allocated = CreateAllocation(B, layout.types.back(), count,
                                      "tmpfortypecalc", &call, &zero);
    auto type = cast<PointerType>(allocated->getType());
    auto raw = cast<PointerType>(call->getType());
    auto allocator = getFunctionFromCall(call);
    layout.packed &= allocator && allocator->getName() == "malloc" &&
                     type->getAddressSpace() == 0 &&
                     raw->getAddressSpace() == 0;
    layout.types.push_back(type);
    layout.mallocTypes.push_back(raw);
  }
  block->eraseFromParent();
  return layout;
}

// Unlike the unit-step exponential allocator, ragged chunks may cross several
// capacity boundaries at once. The caller passes capacities in bytes.
static Function *getRaggedCacheGrower(Module &M, Type *PtrTy, Type *T,
                                      bool zero) {
  auto i64 = Type::getInt64Ty(M.getContext());
  auto FT = FunctionType::get(PtrTy, {PtrTy, i64, i64}, false);
  std::string name =
      zero ? "__enzyme_grow_ragged_cache_zero" : "__enzyme_grow_ragged_cache";
  MDNode *memoryType = nullptr;
  if (T->isFPOrFPVectorTy() || T->isAggregateType()) {
    // The offset table mixes pointers and encoded integers, so type analysis
    // cannot always propagate the element type back through it when taking
    // another reverse derivative. The cache already knows the floating type.
    // Keep different element types in separate helpers before they are inlined.
    std::string typeName;
    raw_string_ostream typeStream(typeName);
    T->print(typeStream, /*IsForDebug=*/false, /*NoDetails=*/true);
    name += "_" + typeStream.str();
    if (T->isFPOrFPVectorTy())
      memoryType =
          MDNode::get(M.getContext(),
                      {MDString::get(M.getContext(),
                                     ConcreteType(T->getScalarType()).str()),
                       ConstantAsMetadata::get(ConstantInt::get(i64, 0))});
  }
  auto F = cast<Function>(M.getOrInsertFunction(name, FT).getCallee());
  if (!F->empty())
    return F;
  F->setLinkage(Function::InternalLinkage);
  F->addFnAttr(Attribute::AlwaysInline);
  F->addFnAttr(Attribute::NoUnwind);
  auto entry = BasicBlock::Create(M.getContext(), "entry", F);
  auto grow = BasicBlock::Create(M.getContext(), "grow", F);
  auto done = BasicBlock::Create(M.getContext(), "done", F);
  IRBuilder<> B(entry);
  auto ptr = F->getArg(0);
  auto oldBytes = F->getArg(1);
  auto newBytes = F->getArg(2);
  B.CreateCondBr(B.CreateICmpUGT(newBytes, oldBytes), grow, done);
  B.SetInsertPoint(grow);
  // Spell growth using operations whose reverse derivatives retain the old
  // allocation until its adjoint is finished. Raw realloc destroys storage
  // needed when differentiating a reverse pass a second time.
  auto mallocF = M.getOrInsertFunction("malloc", PtrTy, i64);
  auto buffer = B.CreateCall(mallocF, {newBytes});
  buffer->addRetAttr(Attribute::NoAlias);
  buffer->addRetAttr(Attribute::NonNull);
  if (T->isAggregateType()) {
    // An array of mixed records cannot describe all repetitions with one
    // enzyme_truetype on a variable-length memcpy. Copy typed elements so
    // nested AD sees the floating fields and their individual types.
    auto copy = BasicBlock::Create(M.getContext(), "copy", F);
    auto copied = BasicBlock::Create(M.getContext(), "copied", F);
    auto elements = B.CreateExactUDiv(
        oldBytes, B.getInt64(M.getDataLayout().getTypeAllocSize(T)));
    auto source = B.CreatePointerCast(ptr, getPointerType(T));
    auto dest = B.CreatePointerCast(buffer, getPointerType(T));
    B.CreateCondBr(B.CreateICmpEQ(elements, B.getInt64(0)), copied, copy);
    B.SetInsertPoint(copy);
    auto index = B.CreatePHI(i64, 2);
    index->addIncoming(B.getInt64(0), grow);
    auto element =
        B.CreateAlignedLoad(T, B.CreateInBoundsGEP(T, source, index), Align(1));
    B.CreateAlignedStore(element, B.CreateInBoundsGEP(T, dest, index),
                         Align(1));
    auto next = B.CreateNUWAdd(index, B.getInt64(1));
    index->addIncoming(next, copy);
    B.CreateCondBr(B.CreateICmpEQ(next, elements), copied, copy);
    B.SetInsertPoint(copied);
  } else {
    auto copy =
        B.CreateMemCpy(buffer, MaybeAlign(1), ptr, MaybeAlign(1), oldBytes);
    if (memoryType)
      copy->setMetadata("enzyme_truetype", memoryType);
  }
  auto freeF = M.getOrInsertFunction("free", B.getVoidTy(), PtrTy);
  auto freeCall = B.CreateCall(freeF, {ptr});
  auto ident = MDNode::getDistinct(M.getContext(),
                                   {ConstantAsMetadata::get(B.getFalse())});
  buffer->setMetadata("enzyme_cache_alloc",
                      MDNode::get(M.getContext(), {ident}));
  freeCall->setMetadata("enzyme_cache_free",
                        MDNode::get(M.getContext(), {ident}));
  if (zero) {
    auto start = B.CreateInBoundsGEP(B.getInt8Ty(), buffer, oldBytes);
    auto clear = B.CreateMemSet(start, B.getInt8(0),
                                B.CreateSub(newBytes, oldBytes), MaybeAlign(1));
    if (memoryType)
      clear->setMetadata("enzyme_truetype", memoryType);
  }
  auto grown = B.GetInsertBlock();
  B.CreateBr(done);
  B.SetInsertPoint(done);
  auto result = B.CreatePHI(PtrTy, 2);
  result->addIncoming(ptr, entry);
  result->addIncoming(buffer, grown);
  B.CreateRet(result);
  return F;
}

/// Erase this instruction both from LLVM modules and any local data-structures
void CacheUtility::erase(Instruction *I) {
  assert(I);

  if (auto found = findInMap(scopeMap, (Value *)I)) {
    scopeFrees.erase(found->first);
    scopeAllocs.erase(found->first);
    scopeInstructions.erase(found->first);
  }
  if (auto AI = dyn_cast<AllocaInst>(I)) {
    scopeFrees.erase(AI);
    scopeAllocs.erase(AI);
    scopeInstructions.erase(AI);
    packedCacheFields.erase(AI);
  }
  scopeMap.erase(I);
  SE.eraseValueFromMap(I);

  if (!I->use_empty()) {
    std::string str;
    raw_string_ostream ss(str);
    ss << "Erased value with a use:\n";
    ss << *newFunc->getParent() << "\n";
    ss << *newFunc << "\n";
    ss << *I << "\n";
    if (CustomErrorHandler) {
      CustomErrorHandler(str.c_str(), wrap(I), ErrorType::InternalError,
                         nullptr, nullptr, nullptr);
    } else {
      EmitFailure("GetIndexError", I->getDebugLoc(), I, ss.str());
    }
    I->replaceAllUsesWith(UndefValue::get(I->getType()));
  }
  assert(I->use_empty());
  I->eraseFromParent();
}

/// Replace this instruction both in LLVM modules and any local data-structures
void CacheUtility::replaceAWithB(Value *A, Value *B, bool storeInCache) {
  auto found = scopeMap.find(A);
  if (found != scopeMap.end()) {
    insert_or_assign2(scopeMap, B, found->second);

    llvm::AllocaInst *cache = found->second.first;
    if (storeInCache) {
      assert(isa<Instruction>(B));
      auto stfound = scopeInstructions.find(cache);
      if (stfound != scopeInstructions.end()) {
        SmallVector<Instruction *, 3> tmpInstructions(stfound->second.begin(),
                                                      stfound->second.end());
        scopeInstructions.erase(stfound);
        for (auto st : tmpInstructions)
          cast<StoreInst>(&*st)->eraseFromParent();
        MDNode *TBAA = nullptr;
        if (auto I = dyn_cast<Instruction>(A))
          TBAA = I->getMetadata(LLVMContext::MD_tbaa);
        storeInstructionInCache(found->second.second, cast<Instruction>(B),
                                cache, TBAA);
      }
    }

    scopeMap.erase(A);
  }
  A->replaceAllUsesWith(B);
}

// Create a new canonical induction variable of Type Ty for Loop L
// Return the variable and the increment instruction
std::pair<PHINode *, Instruction *>
InsertNewCanonicalIV(Loop *L, Type *Ty, const llvm::Twine &Name) {
  assert(L);
  assert(Ty);

  BasicBlock *Header = L->getHeader();
  assert(Header);
  IRBuilder<> B(Header, Header->begin());
  PHINode *CanonicalIV = B.CreatePHI(Ty, 1, Name);

  B.SetInsertPoint(getFirstNonPHIOrDbg(Header));
  Instruction *Inc = cast<Instruction>(
      B.CreateAdd(CanonicalIV, ConstantInt::get(Ty, 1), Name + ".next",
                  /*NUW*/ true, /*NSW*/ true));

  for (BasicBlock *Pred : predecessors(Header)) {
    assert(Pred);
    if (L->contains(Pred)) {
      CanonicalIV->addIncoming(Inc, Pred);
    } else {
      CanonicalIV->addIncoming(ConstantInt::get(Ty, 0), Pred);
    }
  }
  assert(L->getCanonicalInductionVariable() == CanonicalIV);
  return std::pair<PHINode *, Instruction *>(CanonicalIV, Inc);
}

// Create a new canonical induction variable of Type Ty for Loop L
// Return the variable and the increment instruction
std::pair<PHINode *, Instruction *> FindCanonicalIV(Loop *L, Type *Ty) {
  assert(L);
  assert(Ty);

  BasicBlock *Header = L->getHeader();
  assert(Header);
  for (BasicBlock::iterator II = Header->begin(); isa<PHINode>(II); ++II) {
    PHINode *PN = cast<PHINode>(II);
    if (PN->getType() != Ty)
      continue;

    Instruction *Inc = nullptr;
    bool legal = true;
    for (BasicBlock *Pred : predecessors(Header)) {
      assert(Pred);
      if (L->contains(Pred)) {
        auto Inc2 =
            dyn_cast<BinaryOperator>(PN->getIncomingValueForBlock(Pred));
        if (!Inc2 || Inc2->getOpcode() != Instruction::Add ||
            Inc2->getOperand(0) != PN) {
          legal = false;
          break;
        }
        auto CI = dyn_cast<ConstantInt>(Inc2->getOperand(1));
        if (!CI || !CI->isOne()) {
          legal = false;
          break;
        }
        if (Inc) {
          if (Inc2 != Inc) {
            legal = false;
            break;
          }
        } else
          Inc = Inc2;
      } else {
        auto CI = dyn_cast<ConstantInt>(PN->getIncomingValueForBlock(Pred));
        if (!CI || !CI->isZero()) {
          legal = false;
          break;
        }
      }
    }
    if (!legal)
      continue;
    if (!Inc)
      continue;
    if (Inc != getFirstNonPHIOrDbg(Header))
      moveBeforeInst(Inc, getFirstNonPHIOrDbg(Header));
    return std::make_pair(PN, Inc);
  }
  llvm::errs() << *Header << "\n";
  assert(0 && "Could not find canonical IV");
  return std::pair<PHINode *, Instruction *>(nullptr, nullptr);
}

/// Replace every non-affine recurrence (of degree at most three) inside an
/// expression by its closed form in the canonical induction variable of its
/// loop, treated as an opaque value.
///
/// SCEVExpander expands a recurrence with more than two operands literally,
/// as nested loop-carried phis (it would otherwise need a canonical IV one bit
/// wider than the value). Such a phi is as impossible to recompute in the
/// reverse pass as the accumulator it came from, so e.g. the start value
/// i*(2*d-i-1)/2 of an inner index, expanded while rewriting the inner phi,
/// would leave `acc += 2*d-1-2*i` in the outer loop and get cached once per
/// iteration. evaluateAtIterationWithoutExt needs no wider type, so it can
/// take the case the expander declines.
struct NonAffineClosedFormRewriter
    : public SCEVRewriteVisitor<NonAffineClosedFormRewriter> {
  NonAffineClosedFormRewriter(ScalarEvolution &SE) : SCEVRewriteVisitor(SE) {}

  const SCEV *visitAddRecExpr(const SCEVAddRecExpr *AR) {
    // Let the base visitor rewrite the operands (it also copes with the
    // operand representation of the LLVM version at hand).
    const SCEV *R =
        SCEVRewriteVisitor<NonAffineClosedFormRewriter>::visitAddRecExpr(AR);
    auto AR2 = dyn_cast<SCEVAddRecExpr>(R);
    // Beyond degree three the closed form would widen again.
    if (!AR2 || AR2->isAffine() || AR2->getNumOperands() > 4)
      return R;
    if (!AR2->getType()->isIntegerTy())
      return R;
    PHINode *IV = AR2->getLoop()->getCanonicalInductionVariable();
    if (!IV)
      return R;
    return evaluateAtIterationWithoutExt(AR2, SE.getUnknown(IV), SE);
  }
};

// The no-wrap flag type of an add recurrence, named without reference to any
// enumerator (FlagAnyWrap became FlagNone in LLVM 24); its zero value means
// "no flags" in every version.
using NoWrapFlagsTy =
    decltype(std::declval<const SCEVAddRecExpr &>().getNoWrapFlags());

/// PN is a header phi of L that is negated on every iteration, x_{i+1} = -x_i,
/// such as the alternating sign of a cofactor expansion. Scalar evolution
/// cannot express this recurrence, so without a closed form the reverse pass
/// caches its value once per iteration. At iteration I it is x_0 when I is
/// even and -x_0 when I is odd, i.e. x_0 * (1 - 2 * (I mod 2)), with the
/// parity formed as I - 2 * (I / 2) (truncating I keeps its parity).
static const SCEV *closedFormOfNegatingRecurrence(PHINode *PN, Loop *L,
                                                  const SCEV *IterationNumber,
                                                  ScalarEvolution &SE) {
  using namespace llvm::PatternMatch;
  if (!EnzymeRewriteAccumulators)
    return nullptr;
  auto Ty = dyn_cast<IntegerType>(PN->getType());
  if (!Ty || Ty->getBitWidth() < 2 || PN->getNumIncomingValues() != 2)
    return nullptr;
  BasicBlock *Preheader = L->getLoopPreheader();
  BasicBlock *Latch = L->getLoopLatch();
  if (!Preheader || !Latch)
    return nullptr;
  Value *Next = PN->getIncomingValueForBlock(Latch);
  if (!match(Next, m_Neg(m_Specific(PN))) &&
      !match(Next, m_Mul(m_Specific(PN), m_AllOnes())))
    return nullptr;
  const SCEV *Init = SE.getSCEV(PN->getIncomingValueForBlock(Preheader));
  if (!SE.isAvailableAtLoopEntry(Init, L))
    return nullptr;
  const SCEV *I = SE.getTruncateOrZeroExtend(IterationNumber, Ty);
  const SCEV *Two = SE.getConstant(Ty, 2);
  const SCEV *Parity =
      SE.getMinusSCEV(I, SE.getMulExpr(Two, SE.getUDivExpr(I, Two)));
  const SCEV *Factor =
      SE.getMinusSCEV(SE.getOne(Ty), SE.getMulExpr(Two, Parity));
  return SE.getMulExpr(Init, Factor);
}

/// PN is a header phi of L that scalar evolution could not classify. Recognize
/// an accumulator whose per-iteration step is the trip count of an inner loop,
/// as in
///
///   int idx = 0;
///   for (i = 0; i < d; i++)
///     for (j = i + 1; j < d; j++)
///       ... l[idx++] ...
///
/// After loop rotation the latch value of idx reaches PN through a phi that
/// merges "inner loop skipped" with the inner loop's exit value, which SCEV
/// does not see through, so PN stays an unknown and would be cached once per
/// iteration in the reverse pass. Derive the step from that exit value, check
/// that a skipped inner loop contributes exactly zero, and return PN as a
/// closed form in the iteration number (a polynomial, quadratic here), or
/// nullptr when the shape does not match or the proofs fail.
static const SCEV *closedFormOfCountedAccumulator(PHINode *PN, Loop *L,
                                                  const SCEV *IterationNumber,
                                                  ScalarEvolution &SE) {
  if (!EnzymeRewriteAccumulators)
    return nullptr;
  // Integer counters only: a pointer recurrence has no closed form to expand.
  if (!PN->getType()->isIntegerTy() || PN->getNumIncomingValues() != 2)
    return nullptr;
  BasicBlock *Preheader = L->getLoopPreheader();
  BasicBlock *Latch = L->getLoopLatch();
  if (!Preheader || !Latch)
    return nullptr;
  Value *Init = PN->getIncomingValueForBlock(Preheader);
  Value *Next = PN->getIncomingValueForBlock(Latch);
  const SCEV *InitS = SE.getSCEV(Init);
  if (!SE.isAvailableAtLoopEntry(InitS, L))
    return nullptr;
  const SCEV *PNS = SE.getSCEV(PN);

  // The arms the latch value can take, each with the block it comes from.
  SmallVector<std::pair<Value *, BasicBlock *>, 2> Arms;
  // The block that merges the arms, i.e. where each arm's edge leads.
  BasicBlock *Merge = Latch;
  if (auto NP = dyn_cast<PHINode>(Next); NP && NP != PN &&
                                         NP->getParent() != L->getHeader() &&
                                         L->contains(NP->getParent())) {
    Merge = NP->getParent();
    for (unsigned i = 0; i < NP->getNumIncomingValues(); i++)
      Arms.emplace_back(NP->getIncomingValue(i), NP->getIncomingBlock(i));
  } else {
    Arms.emplace_back(Next, Latch);
  }

  // The recurrence may be carried in a wider type than PN (e.g. an i32 index
  // sign-extended to i64 for addressing, then truncated back). Work in that
  // type, where trunc(ext(PN) + step) - PN cancels exactly.
  Type *WideTy = PN->getType();
  bool Signed = true;
  const SCEV *Step = nullptr;
  SmallVector<BasicBlock *, 2> ZeroArms;
  for (auto &Arm : Arms) {
    Value *V = Arm.first;
    if (V == PN) {
      ZeroArms.push_back(Arm.second);
      continue;
    }
    Value *Wide = V;
    if (auto TI = dyn_cast<TruncInst>(V))
      Wide = TI->getOperand(0);
    Type *Ty = Wide->getType();
    if (!Ty->isIntegerTy())
      return nullptr;
    // At the scope of L, a value from an inner loop is its exit value.
    const SCEV *WS = SE.getSCEVAtScope(Wide, L);
    if (WS == SE.getCouldNotCompute())
      return nullptr;
    const SCEV *D = nullptr;
    bool Sgn = true;
    for (bool S : {true, false}) {
      const SCEV *Ext =
          S ? SE.getNoopOrSignExtend(PNS, Ty) : SE.getNoopOrZeroExtend(PNS, Ty);
      const SCEV *Cand = SE.getMinusSCEV(WS, Ext);
      if (isa<SCEVCouldNotCompute>(Cand))
        continue;
      if (!SCEVExprContains(Cand, [&](const SCEV *X) { return X == PNS; })) {
        D = Cand;
        Sgn = S;
        break;
      }
    }
    if (!D)
      return nullptr;
    if (Step) {
      if (D != Step || Ty != WideTy || Sgn != Signed)
        return nullptr;
    } else {
      Step = D;
      WideTy = Ty;
      Signed = Sgn;
    }
  }
  if (!Step)
    return nullptr;

  // The step must be invariant or affine in L's own counter, with nothing
  // from an inner loop left over.
  if (SCEVExprContains(Step, [&](const SCEV *X) {
        auto AR = dyn_cast<SCEVAddRecExpr>(X);
        return AR && AR->getLoop() != L && !AR->getLoop()->contains(L);
      }))
    return nullptr;
  auto Disp = SE.getLoopDisposition(Step, L);
  if (Disp == ScalarEvolution::LoopVariant)
    return nullptr;
  if (auto AR = dyn_cast<SCEVAddRecExpr>(Step)) {
    if (AR->getLoop() != L || !AR->isAffine())
      return nullptr;
  } else if (Disp != ScalarEvolution::LoopInvariant) {
    return nullptr;
  }

  // The closed form adds Step on every iteration, including those where the
  // inner loop was skipped and PN was carried unchanged, so on those the step
  // must be exactly zero. Show that in two halves: Step is never negative on
  // any iteration, and Step is non-positive wherever a skipping edge is taken.
  if (!ZeroArms.empty()) {
    auto AR = dyn_cast<SCEVAddRecExpr>(Step);
    if (!AR)
      return nullptr;
    const SCEV *Zero = SE.getZero(WideTy);

    // Step >= 0 everywhere. Ask SCEV first; failing that, an affine step with
    // a constant increment is monotone, so it suffices to check it at the
    // first or the last iteration.
    bool NonNegative = SE.isKnownOnEveryIteration(ICmpInst::ICMP_SGE, AR, Zero);
    if (!NonNegative) {
      auto C = dyn_cast<SCEVConstant>(AR->getStepRecurrence(SE));
      if (!C)
        return nullptr;
      if (C->getAPInt().isNonNegative()) {
        NonNegative = SE.isKnownNonNegative(AR->getStart()) ||
                      SE.isLoopEntryGuardedByCond(L, ICmpInst::ICMP_SGE,
                                                  AR->getStart(), Zero);
      } else {
        const SCEV *BTC = SE.getBackedgeTakenCount(L);
        if (BTC == SE.getCouldNotCompute())
          return nullptr;
        NonNegative = SE.isKnownNonNegative(AR->evaluateAtIteration(BTC, SE));
      }
    }
    if (!NonNegative)
      return nullptr;

    // Step <= 0 on each skipping edge. The edge B -> Merge is taken on one
    // outcome of a branch on `icmp P A, B`: the conditional branch that ends
    // B, or, when B is a block that exists only to carry the edge, the one
    // that ends B's single predecessor. Orient the predicate that holds on
    // the edge as X >= Y, X > Y or X == Y and require Step == (Y - X) + k for
    // a constant k that then makes Step non-positive. Both X and Y must be
    // known non-negative so that Y - X cannot wrap.
    for (auto B : ZeroArms) {
      BasicBlock *Dest = Merge;
      Instruction *TI = B->getTerminator();
      if (!isConditionalBranch(TI)) {
        if (TI->getNumSuccessors() != 1)
          return nullptr;
        BasicBlock *Pred = B->getSinglePredecessor();
        if (!Pred)
          return nullptr;
        Dest = B;
        TI = Pred->getTerminator();
        if (!isConditionalBranch(TI))
          return nullptr;
      }
      if (TI->getSuccessor(0) == TI->getSuccessor(1) ||
          (TI->getSuccessor(0) != Dest && TI->getSuccessor(1) != Dest))
        return nullptr;
      auto Cmp = dyn_cast<ICmpInst>(getBranchCondition(TI));
      if (!Cmp)
        return nullptr;
      ICmpInst::Predicate Q = Cmp->getPredicate();
      if (TI->getSuccessor(1) == Dest)
        Q = ICmpInst::getInversePredicate(Q);
      Value *X = Cmp->getOperand(0), *Y = Cmp->getOperand(1);
      bool Strict = false, Equal = false;
      switch (Q) {
      case ICmpInst::ICMP_UGE:
      case ICmpInst::ICMP_SGE:
        break;
      case ICmpInst::ICMP_ULE:
      case ICmpInst::ICMP_SLE:
        std::swap(X, Y);
        break;
      case ICmpInst::ICMP_UGT:
      case ICmpInst::ICMP_SGT:
        Strict = true;
        break;
      case ICmpInst::ICMP_ULT:
      case ICmpInst::ICMP_SLT:
        std::swap(X, Y);
        Strict = true;
        break;
      case ICmpInst::ICMP_EQ:
        Equal = true;
        break;
      default:
        return nullptr;
      }
      if (!SE.isSCEVable(X->getType()) || X->getType() != WideTy)
        return nullptr;
      const SCEV *XS = SE.getSCEV(X), *YS = SE.getSCEV(Y);
      auto NonNeg = [&](const SCEV *V) {
        return SE.isKnownNonNegative(V) ||
               SE.isLoopEntryGuardedByCond(L, ICmpInst::ICMP_SGE, V, Zero);
      };
      if (!Equal && !(NonNeg(XS) && NonNeg(YS)))
        return nullptr;
      auto K = dyn_cast<SCEVConstant>(
          SE.getMinusSCEV(Step, SE.getMinusSCEV(YS, XS)));
      if (!K)
        return nullptr;
      // On the edge, Y - X is 0 (Equal), <= 0 (non-strict) or <= -1 (Strict).
      if (Equal ? !K->getAPInt().isZero() : K->getAPInt().sgt(Strict ? 1 : 0))
        return nullptr;
    }
  }

  const SCEV *WideInit = Signed ? SE.getNoopOrSignExtend(InitS, WideTy)
                                : SE.getNoopOrZeroExtend(InitS, WideTy);
  auto AR = dyn_cast<SCEVAddRecExpr>(
      SE.getAddRecExpr(WideInit, Step, L, NoWrapFlagsTy(0)));
  if (!AR)
    return nullptr;
  return SE.getTruncateOrNoop(
      evaluateAtIterationWithoutExt(AR, IterationNumber, SE), PN->getType());
}

// Attempt to rewrite all phinode's in the loop in terms of the
// induction variable
void RemoveRedundantIVs(
    Loop *L, PHINode *CanonicalIV, Instruction *Increment,
    MustExitScalarEvolution &SE,
    llvm::function_ref<void(Instruction *, Value *)> replacer,
    llvm::function_ref<void(Instruction *)> eraser) {
  BasicBlock *Header = L->getHeader();
  assert(Header);
  assert(CanonicalIV);
  SmallVector<Instruction *, 8> IVsToRemove;

  auto CanonicalSCEV = SE.getSCEV(CanonicalIV);

  for (BasicBlock::iterator II = Header->begin(); isa<PHINode>(II);) {
    PHINode *PN = cast<PHINode>(II);
    ++II;
    if (PN == CanonicalIV)
      continue;
    if (!SE.isSCEVable(PN->getType()))
      continue;
    const SCEV *S = SE.getSCEV(PN);
    if (SE.getCouldNotCompute() == S || isa<SCEVUnknown>(S)) {
      // Evaluate at the canonical IV as an opaque value rather than as its
      // add-recurrence: otherwise SCEV folds the polynomial back into a
      // higher-degree recurrence, which the expander would materialize as a
      // fresh loop-carried phi, defeating the purpose.
      const SCEV *IterationNumber = SE.getUnknown(CanonicalIV);
      S = closedFormOfNegatingRecurrence(PN, L, IterationNumber, SE);
      if (!S)
        S = closedFormOfCountedAccumulator(PN, L, IterationNumber, SE);
      if (!S)
        continue;
    } else if (EnzymeRewriteAccumulators) {
      S = NonAffineClosedFormRewriter(SE).visit(S);
    }
    // we may expand code for phi where not legal (computing with
    // subloop expressions). Check that this isn't the case
    if (!SE.dominates(S, Header))
      continue;

    if (S == CanonicalSCEV) {
      replacer(PN, CanonicalIV);
      eraser(PN);
      continue;
    }

    IRBuilder<> B(PN);
    auto Tmp = B.CreatePHI(PN->getType(), 0);
    for (auto Pred : predecessors(Header))
      Tmp->addIncoming(UndefValue::get(Tmp->getType()), Pred);
    replacer(PN, Tmp);
    eraser(PN);

    // This scope is necessary to ensure scevexpander cleans up before we erase
    // things
#if LLVM_VERSION_MAJOR >= 22 && !defined(ENZYME_LLVM22_PRERELEASE)
    SCEVExpander Exp(SE, "enzyme");
#else
    SCEVExpander Exp(SE, Header->getParent()->getParent()->getDataLayout(),
                     "enzyme");
#endif

    // We place that at first non phi as it may produce a non-phi instruction
    // and must thus be expanded after all phi's
    Value *NewIV = Exp.expandCodeFor(S, Tmp->getType(), getFirstNonPHI(Header));

    // Explicity preserve wrap behavior from original iv. This is necessary
    // until this PR in llvm is merged:
    //    https://github.com/llvm/llvm-project/pull/78199
    if (auto addrec = dyn_cast<SCEVAddRecExpr>(S)) {
      if (addrec->getLoop()->getHeader() == Header) {
        if (auto add_or_mul = dyn_cast<BinaryOperator>(NewIV)) {
#if LLVM_VERSION_MAJOR >= 23
          if (any(addrec->getNoWrapFlags(llvm::SCEV::FlagNUW)))
            add_or_mul->setHasNoUnsignedWrap(true);
          if (any(addrec->getNoWrapFlags(llvm::SCEV::FlagNSW)))
            add_or_mul->setHasNoSignedWrap(true);
#else
          if (addrec->getNoWrapFlags(llvm::SCEV::FlagNUW))
            add_or_mul->setHasNoUnsignedWrap(true);
          if (addrec->getNoWrapFlags(llvm::SCEV::FlagNSW))
            add_or_mul->setHasNoSignedWrap(true);
#endif
        }
      }
    }
    replacer(Tmp, NewIV);
    eraser(Tmp);
  }

  // Replace existing increments with canonical Increment
  Increment->moveAfter(getFirstNonPHI(CanonicalIV->getParent()));
  SmallVector<Instruction *, 1> toErase;
  for (auto use : CanonicalIV->users()) {
    auto BO = dyn_cast<BinaryOperator>(use);
    if (BO == nullptr)
      continue;
    if (BO->getOpcode() != BinaryOperator::Add)
      continue;
    if (use == Increment)
      continue;

    Value *toadd = nullptr;
    if (BO->getOperand(0) == CanonicalIV) {
      toadd = BO->getOperand(1);
    } else {
      assert(BO->getOperand(1) == CanonicalIV);
      toadd = BO->getOperand(0);
    }
    if (auto CI = dyn_cast<ConstantInt>(toadd)) {
      if (!CI->isOne())
        continue;
      BO->replaceAllUsesWith(Increment);
      toErase.push_back(BO);
    } else {
      continue;
    }
  }
  for (auto BO : toErase)
    eraser(BO);
}

void CanonicalizeLatches(const Loop *L, BasicBlock *Header,
                         BasicBlock *Preheader, PHINode *CanonicalIV,
                         MustExitScalarEvolution &SE, CacheUtility &gutils,
                         Instruction *Increment,
                         ArrayRef<BasicBlock *> latches) {
  // Attempt to explicitly rewrite the latch
  if (latches.size() == 1 && isConditionalBranch(latches[0]->getTerminator()))
    for (auto use : CanonicalIV->users()) {
      if (auto cmp = dyn_cast<ICmpInst>(use)) {
        if (getBranchCondition(latches[0]->getTerminator()) != cmp)
          continue;
        // Force i to be on LHS
        if (cmp->getOperand(0) != CanonicalIV) {
          // Below also swaps predicate correctly
          cmp->swapOperands();
        }
        assert(cmp->getOperand(0) == CanonicalIV);

        auto scv = SE.getSCEVAtScope(cmp->getOperand(1), L);
        if (cmp->isUnsigned() ||
            (scv != SE.getCouldNotCompute() && SE.isKnownNonNegative(scv))) {

          // valid replacements (since unsigned comparison and i starts at 0
          // counting up)

          // * i < n => i != n, valid since first time i >= n occurs at i == n
          if (cmp->getPredicate() == ICmpInst::ICMP_ULT ||
              cmp->getPredicate() == ICmpInst::ICMP_SLT) {
            cmp->setPredicate(ICmpInst::ICMP_NE);
            goto cend;
          }

          // * i <= n => i != n+1, valid since first time i > n occurs at i ==
          // n+1 [ which we assert is in bitrange as not infinite loop ]
          if (cmp->getPredicate() == ICmpInst::ICMP_ULE ||
              cmp->getPredicate() == ICmpInst::ICMP_SLE) {
            IRBuilder<> builder(Preheader->getTerminator());
            if (auto inst = dyn_cast<Instruction>(cmp->getOperand(1))) {
              builder.SetInsertPoint(inst->getNextNode());
            }
            cmp->setOperand(
                1,
                builder.CreateNUWAdd(
                    cmp->getOperand(1),
                    ConstantInt::get(cmp->getOperand(1)->getType(), 1, false)));
            cmp->setPredicate(ICmpInst::ICMP_NE);
            goto cend;
          }

          // * i >= n => i == n, valid since first time i >= n occurs at i == n
          if (cmp->getPredicate() == ICmpInst::ICMP_UGE ||
              cmp->getPredicate() == ICmpInst::ICMP_SGE) {
            cmp->setPredicate(ICmpInst::ICMP_EQ);
            goto cend;
          }

          // * i > n => i == n+1, valid since first time i > n occurs at i ==
          // n+1 [ which we assert is in bitrange as not infinite loop ]
          if (cmp->getPredicate() == ICmpInst::ICMP_UGT ||
              cmp->getPredicate() == ICmpInst::ICMP_SGT) {
            IRBuilder<> builder(Preheader->getTerminator());
            if (auto inst = dyn_cast<Instruction>(cmp->getOperand(1))) {
              builder.SetInsertPoint(inst->getNextNode());
            }
            cmp->setOperand(
                1,
                builder.CreateNUWAdd(
                    cmp->getOperand(1),
                    ConstantInt::get(cmp->getOperand(1)->getType(), 1, false)));
            cmp->setPredicate(ICmpInst::ICMP_EQ);
            goto cend;
          }
        }
      cend:;
        if (cmp->getPredicate() == ICmpInst::ICMP_NE) {
        }
      }
    }

  // Replace previous increment usage with new increment value
  if (Increment) {
    Increment->moveAfter(getFirstNonPHI(CanonicalIV->getParent()));

    if (latches.size() == 1 && isConditionalBranch(latches[0]->getTerminator()))
      for (auto use : Increment->users()) {
        if (auto cmp = dyn_cast<ICmpInst>(use)) {
          if (getBranchCondition(latches[0]->getTerminator()) != cmp)
            continue;

          // Force i+1 to be on LHS
          if (cmp->getOperand(0) != Increment) {
            // Below also swaps predicate correctly
            cmp->swapOperands();
          }
          assert(cmp->getOperand(0) == Increment);

          auto scv = SE.getSCEVAtScope(cmp->getOperand(1), L);
          if (cmp->isUnsigned() ||
              (scv != SE.getCouldNotCompute() && SE.isKnownNonNegative(scv))) {

            // valid replacements (since unsigned comparison and i starts at 0
            // counting up)

            // * i+1 < n => i+1 != n, valid since first time i+1 >= n occurs at
            // i+1 == n
            if (cmp->getPredicate() == ICmpInst::ICMP_ULT ||
                cmp->getPredicate() == ICmpInst::ICMP_SLT) {
              cmp->setPredicate(ICmpInst::ICMP_NE);
              continue;
            }

            // * i+1 <= n => i != n, valid since first time i+1 > n occurs at
            // i+1 == n+1 => i == n
            if (cmp->getPredicate() == ICmpInst::ICMP_ULE ||
                cmp->getPredicate() == ICmpInst::ICMP_SLE) {
              cmp->setOperand(0, CanonicalIV);
              cmp->setPredicate(ICmpInst::ICMP_NE);
              continue;
            }

            // * i+1 >= n => i+1 == n, valid since first time i+1 >= n occurs at
            // i+1 == n
            if (cmp->getPredicate() == ICmpInst::ICMP_UGE ||
                cmp->getPredicate() == ICmpInst::ICMP_SGE) {
              cmp->setPredicate(ICmpInst::ICMP_EQ);
              continue;
            }

            // * i+1 > n => i == n, valid since first time i+1 > n occurs at i+1
            // == n+1 => i == n
            if (cmp->getPredicate() == ICmpInst::ICMP_UGT ||
                cmp->getPredicate() == ICmpInst::ICMP_SGT) {
              cmp->setOperand(0, CanonicalIV);
              cmp->setPredicate(ICmpInst::ICMP_EQ);
              continue;
            }
          }
        }
      }
  }
}

llvm::AllocaInst *CacheUtility::getDynamicLoopLimit(llvm::Loop *L,
                                                    bool ReverseLimit) {
  assert(L);
  assert(loopContexts.find(L) != loopContexts.end());
  auto &found = loopContexts[L];
  assert(found.dynamic);
  if (found.trueLimit)
    return cast<AllocaInst>(&*found.trueLimit);

  LimitContext lctx(ReverseLimit,
                    ReverseLimit ? found.preheader : &newFunc->getEntryBlock());
  AllocaInst *LimitVar =
      createCacheForScope(lctx, found.var->getType(), "loopLimit",
                          /*shouldfree*/ true);

  for (auto ExitBlock : found.exitBlocks) {
    IRBuilder<> B(ExitBlock, ExitBlock->begin());
    auto Limit = B.CreatePHI(found.var->getType(), 1);

    for (BasicBlock *Pred : predecessors(ExitBlock)) {
      if (L->contains(Pred)) {
        Limit->addIncoming(found.var, Pred);
      } else {
        Limit->addIncoming(UndefValue::get(found.var->getType()), Pred);
      }
    }

    storeInstructionInCache(lctx, Limit, LimitVar);
  }
  found.trueLimit = LimitVar;
  return LimitVar;
}

/// Compute the exact backedge-taken count of L (CouldNotCompute if it is not
/// statically known) and the maximum number of iterations, ignoring exits that
/// are guaranteed to reach unreachable.
std::pair<const SCEV *, const SCEV *> CacheUtility::computeLoopLimit(Loop *L) {
  const SCEV *MaxIterations = nullptr;
  const SCEV *MayExitMaxBECount = nullptr;

  SmallVector<BasicBlock *, 8> ExitingBlocks;
  L->getExitingBlocks(ExitingBlocks);

  // Remove all exiting blocks that are guaranteed
  // to result in unreachable
  for (auto &ExitingBlock : ExitingBlocks) {
    BasicBlock *Exit = nullptr;
    for (auto *SBB : successors(ExitingBlock)) {
      if (!L->contains(SBB)) {
        if (SE.GuaranteedUnreachable.count(SBB))
          continue;
        Exit = SBB;
        break;
      }
    }
    if (!Exit)
      ExitingBlock = nullptr;
  }
  ExitingBlocks.erase(
      std::remove(ExitingBlocks.begin(), ExitingBlocks.end(), nullptr),
      ExitingBlocks.end());

  // Compute the exit in the scenarios where an unreachable
  // is not hit
  for (BasicBlock *ExitingBlock : ExitingBlocks) {
    assert(L->contains(ExitingBlock));

    ScalarEvolution::ExitLimit EL =
        SE.computeExitLimit(L, ExitingBlock, /*AllowPredicates*/ true);

    bool seenHeaders = false;
    SmallPtrSet<BasicBlock *, 4> Seen;
    std::deque<BasicBlock *> Todo = {ExitingBlock};
    while (Todo.size()) {
      auto cur = Todo.front();
      Todo.pop_front();
      if (Seen.count(cur))
        continue;
      if (!L->contains(cur))
        continue;
      if (cur == L->getHeader()) {
        seenHeaders = true;
        break;
      }
      for (auto S : successors(cur)) {
        Todo.push_back(S);
      }
    }
    if (seenHeaders) {
      // An exit whose exact count is unknown, such as a convergence check
      // combined with an iteration bound, may still bound the loop through
      // the constant maximum of the exit limit.
      const SCEV *ExitBound = EL.ExactNotTaken;
      if (ExitBound == SE.getCouldNotCompute())
#if LLVM_VERSION_MAJOR >= 16
        ExitBound = EL.ConstantMaxNotTaken;
#else
        ExitBound = EL.MaxNotTaken;
#endif
      if (MaxIterations == nullptr ||
          MaxIterations == SE.getCouldNotCompute()) {
        MaxIterations = ExitBound;
      }
      if (MaxIterations != SE.getCouldNotCompute()) {
        if (ExitBound != SE.getCouldNotCompute()) {
          MaxIterations =
              SE.getUMaxFromMismatchedTypes(MaxIterations, ExitBound);
        }
      }

      if (MayExitMaxBECount == nullptr ||
          EL.ExactNotTaken == SE.getCouldNotCompute())
        MayExitMaxBECount = EL.ExactNotTaken;

      if (EL.ExactNotTaken != MayExitMaxBECount) {
        MayExitMaxBECount = SE.getCouldNotCompute();
      }
    }
  }
  if (MayExitMaxBECount == nullptr) {
    MayExitMaxBECount = SE.getCouldNotCompute();
  }
  if (MaxIterations == nullptr) {
    MaxIterations = SE.getCouldNotCompute();
  }
  return std::make_pair(MayExitMaxBECount, MaxIterations);
}

bool CacheUtility::getContext(BasicBlock *BB, LoopContext &loopContext,
                              bool ReverseLimit) {
  assert(BB->getParent() == newFunc);
  Loop *L = LI.getLoopFor(BB);

  // Not inside a loop
  if (L == nullptr)
    return false;

  // Previously handled this loop
  if (auto found = findInMap(loopContexts, L)) {
    loopContext = *found;
    return true;
  }

  // Need to canonicalize
  loopContexts[L].parent = L->getParentLoop();

  loopContexts[L].header = L->getHeader();
  assert(loopContexts[L].header && "loop must have header");

  loopContexts[L].preheader = L->getLoopPreheader();
  if (!L->getLoopPreheader()) {
    llvm::errs() << "fn: " << *L->getHeader()->getParent() << "\n";
    llvm::errs() << "L: " << *L << "\n";
  }
  assert(loopContexts[L].preheader && "loop must have preheader");
  getExitBlocks(L, loopContexts[L].exitBlocks);

  loopContexts[L].offset = nullptr;
  loopContexts[L].allocLimit = nullptr;
  // A precisely matching canonical IV shouldve been run during preprocessing.
  auto pair = FindCanonicalIV(L, Type::getInt64Ty(BB->getContext()));
  PHINode *CanonicalIV = pair.first;
  auto incVar = pair.second;
  assert(CanonicalIV);
  loopContexts[L].var = CanonicalIV;
  loopContexts[L].incvar = incVar;
  CanonicalizeLatches(L, loopContexts[L].header, loopContexts[L].preheader,
                      CanonicalIV, SE, *this, incVar,
                      getLatches(L, loopContexts[L].exitBlocks));
  loopContexts[L].antivaralloc =
      IRBuilder<>(inversionAllocs)
          .CreateAlloca(CanonicalIV->getType(), nullptr,
                        CanonicalIV->getName() + "'ac");
  loopContexts[L].antivaralloc->setAlignment(
      Align(cast<IntegerType>(CanonicalIV->getType())->getBitWidth() / 8));

  const SCEV *Limit = nullptr;
  const SCEV *MaxIterations = nullptr;
  std::tie(Limit, MaxIterations) = computeLoopLimit(L);
  assert(Limit);
  Value *LimitVar = nullptr;

  if (SE.getCouldNotCompute() != Limit) {

    if (CanonicalIV == nullptr) {
      report_fatal_error("Couldn't get canonical IV.");
    }

    // A loop over the chunk of an OpenMP worksharing loop assigned to this
    // thread runs from the lower to the upper bound __kmpc_for_static_init
    // stored for it. Size its cache for the iterations of all threads, as
    // computable before the parallel region, and offset each thread's part
    // by where its chunk starts. A loop whose limit was derived from these
    // bounds otherwise (e.g. vectorized, or the remainder of a vectorized
    // loop) runs at most as many iterations as its chunk has, so the same
    // offset keeps the parts of different threads disjoint.
    {
      SmallVector<const SCEV *, 4> Todo = {Limit};
      SmallPtrSet<const SCEV *, 8> Seen;
      CallInst *ompInit = nullptr;
      LoadInst *boundLoad = nullptr;
      while (Todo.size() && !ompInit) {
        auto S = Todo.pop_back_val();
        if (!Seen.insert(S).second)
          continue;
        auto U = dyn_cast<SCEVUnknown>(S);
        if (!U) {
          // SCEV::operands() needs LLVM 16.
          if (auto N = dyn_cast<SCEVNAryExpr>(S))
            for (auto op : N->operands())
              Todo.push_back(op);
          else if (auto C = dyn_cast<SCEVCastExpr>(S))
            Todo.push_back(C->getOperand());
          else if (auto D = dyn_cast<SCEVUDivExpr>(S)) {
            Todo.push_back(D->getLHS());
            Todo.push_back(D->getRHS());
          }
          continue;
        }
        auto LI = dyn_cast<LoadInst>(U->getValue());
        if (!LI)
          continue;
        auto AI = dyn_cast<AllocaInst>(LI->getPointerOperand());
        if (!AI)
          continue;
        for (auto u : AI->users()) {
          auto call = dyn_cast<CallInst>(u);
          if (!call)
            continue;
          Function *F = call->getCalledFunction();
          if (!F)
            continue;
          if ((F->getName() == "__kmpc_for_static_init_4" ||
               F->getName() == "__kmpc_for_static_init_4u" ||
               F->getName() == "__kmpc_for_static_init_8" ||
               F->getName() == "__kmpc_for_static_init_8u") &&
              (call->getArgOperand(4) == AI || call->getArgOperand(5) == AI)) {
            ompInit = call;
            boundLoad = LI;
            break;
          }
        }
      }
      if (ompInit) {
        auto storedValue = [](Value *ptr) -> Value * {
          for (auto u : ptr->users())
            if (auto si = dyn_cast<StoreInst>(u))
              if (si->getPointerOperand() == ptr)
                return si->getValueOperand();
          return nullptr;
        };
        Value *lb = storedValue(ompInit->getArgOperand(4));
        Value *ub = storedValue(ompInit->getArgOperand(5));
        assert(lb);
        assert(ub);
        // The lower bound of this thread's chunk, as loaded after the call.
        Value *omp_lb_post = nullptr;
        if (boundLoad->getPointerOperand() == ompInit->getArgOperand(4))
          omp_lb_post = boundLoad;
        else
          for (auto u : ompInit->getArgOperand(4)->users())
            if (auto LI = dyn_cast<LoadInst>(u))
              if (LI->getParent() == ompInit->getParent() &&
                  ompInit->comesBefore(LI)) {
                omp_lb_post = LI;
                break;
              }
        IRBuilder<> post(ompInit->getNextNode());
        if (omp_lb_post)
          post.SetInsertPoint(cast<Instruction>(omp_lb_post)->getNextNode());
        else
          omp_lb_post = post.CreateLoad(
              lb->getType(), ompInit->getArgOperand(4), "omp_lb_post");
        loopContexts[L].allocLimit = post.CreateZExtOrTrunc(
            post.CreateSub(ub, lb), CanonicalIV->getType());
        loopContexts[L].offset = post.CreateZExtOrTrunc(
            post.CreateSub(omp_lb_post, lb, "", true, true),
            CanonicalIV->getType());
      }
    }

    if (Limit->getType() != CanonicalIV->getType()) {
      const SCEV *Zero = SE.getZero(Limit->getType());
      const Loop *outermost = L;
      while (outermost->getParentLoop()) {
        outermost = outermost->getParentLoop();
      }
      BasicBlock *outermostPreheader = outermost->getLoopPreheader();
      Instruction *context = outermostPreheader
                                 ? outermostPreheader->getTerminator()
                                 : loopContexts[L].preheader->getTerminator();
      if (SE.isKnownPredicateAt(ICmpInst::ICMP_SGE, Limit, Zero, context)) {
        Limit = SE.getZeroExtendExpr(Limit, CanonicalIV->getType());
      } else {
        Limit = SE.getSignExtendExpr(Limit, CanonicalIV->getType());
      }
    }

#if LLVM_VERSION_MAJOR >= 22 && !defined(ENZYME_LLVM22_PRERELEASE)
    SCEVExpander Exp(SE, "enzyme");
#else
    SCEVExpander Exp(SE, BB->getParent()->getParent()->getDataLayout(),
                     "enzyme");
#endif
    LimitVar = Exp.expandCodeFor(Limit, CanonicalIV->getType(),
                                 loopContexts[L].preheader->getTerminator());
    loopContexts[L].dynamic = false;
    loopContexts[L].maxLimit = LimitVar;
  } else {
    // TODO if assumeDynamicLoopOfSizeOne(L), only lazily allocate the scope
    // cache
    DebugLoc loc = L->getHeader()->begin()->getDebugLoc();
    for (auto &I : *L->getHeader()) {
      if (loc)
        break;
      loc = I.getDebugLoc();
    }
    EmitWarning("NoLimit", loc, L->getHeader(),
                "SE could not compute loop limit of ",
                L->getHeader()->getName(), " of ",
                L->getHeader()->getParent()->getName(), "lim: ", *Limit,
                " maxlim: ", *MaxIterations);

    loopContexts[L].dynamic = true;
    loopContexts[L].maxLimit = nullptr;

    if (assumeDynamicLoopOfSizeOne(L)) {
      LimitVar = nullptr;
    } else {
      LimitVar = getDynamicLoopLimit(L, ReverseLimit);
    }
  }
  loopContexts[L].trueLimit = LimitVar;
  if (EfficientMaxCache && loopContexts[L].dynamic &&
      SE.getCouldNotCompute() != MaxIterations) {
    if (MaxIterations->getType() != CanonicalIV->getType())
      MaxIterations =
          SE.getZeroExtendExpr(MaxIterations, CanonicalIV->getType());

#if LLVM_VERSION_MAJOR >= 22 && !defined(ENZYME_LLVM22_PRERELEASE)
    SCEVExpander Exp(SE, "enzyme");
#else
    SCEVExpander Exp(SE, BB->getParent()->getParent()->getDataLayout(),
                     "enzyme");
#endif

    loopContexts[L].maxLimit =
        Exp.expandCodeFor(MaxIterations, CanonicalIV->getType(),
                          loopContexts[L].preheader->getTerminator());
  }
  loopContext = loopContexts.find(L)->second;
  return true;
}

// The root table retains the ordinary tape pointer type. Its first N-1
// entries point to the current buffers (values at 0, offsets at 1..N-2).
// The remaining entries store the offsets of the outermost chunk. Every
// offset is an element index, so a buffer can move without fixing pointers.
static Value *packedSlot(IRBuilder<> &B, Value *table, Type *slotType,
                         unsigned buffers, ArrayRef<Value *> indices) {
  Value *slot = B.CreateInBoundsGEP(
      slotType, table, B.CreateAdd(indices.front(), B.getInt64(buffers)));
  for (unsigned k = 1; k < indices.size(); ++k) {
    auto offset =
        B.CreatePtrToInt(B.CreateLoad(slotType, slot), B.getInt64Ty());
    auto header = B.CreateInBoundsGEP(slotType, table, B.getInt64(buffers - k));
    auto offsets =
        B.CreatePointerCast(B.CreateLoad(slotType, header), table->getType());
    slot = B.CreateInBoundsGEP(slotType, offsets,
                               B.CreateNUWAdd(offset, indices[k]));
  }
  return slot;
}

static Instruction *previousInstruction(IRBuilder<> &B) {
  auto pos = B.GetInsertPoint();
  return pos == B.GetInsertBlock()->begin() ? nullptr : &*std::prev(pos);
}

void CacheUtility::recordCacheInstructions(AllocaInst *owner, IRBuilder<> &B,
                                           Instruction *before) {
  if (!owner)
    return;
  auto start =
      before ? std::next(before->getIterator()) : B.GetInsertBlock()->begin();
  for (; start != B.GetInsertPoint(); ++start)
    scopeInstructions[owner].push_back(&*start);
}

void CacheUtility::createPackedCache(AllocaInst *alloc,
                                     const SubLimitType &sublimits,
                                     ArrayRef<Type *> types, Type *rawPtr,
                                     StringRef name, bool shouldFree,
                                     bool allocateInternal, Value *extraSize) {
  unsigned buffers = sublimits.size() - 1;
  Type *slotType = types[buffers];
  Type *rootType = types.back();
  const auto &DL = newFunc->getParent()->getDataLayout();
  IRBuilder<> entry(inversionAllocs);
  auto i64 = entry.getInt64Ty();
  auto slotBytes = entry.getInt64(DL.getPointerSize());
  auto outer = sublimits.back().second.back().first.preheader;
  bool shared = allocateInternal && !extraSize && EnzymeGroupPackedCaches &&
                groupPackedCaches();
  PackedCacheGroup single;
  PackedCacheGroup *group = &single;
  if (shared) {
    PackedNest nest;
    for (const auto &chunk : sublimits) {
      nest.emplace_back(chunk.first, chunk.second.back().first.preheader);
      for (const auto &loop : chunk.second)
        nest.emplace_back(loop.second, loop.first.header);
    }
    group =
        &packedCacheGroups[std::make_tuple(types.front(), nest, shouldFree)];
  }

  // In split reverse alloc is filled from the tape. Emit only its cleanup.
  if (!group->table) {
    AllocaInst *owner = shared ? nullptr : alloc;
    auto root =
        shared ? entry.CreateAlloca(rootType, nullptr, name + "_group") : alloc;
    group->table = root;
    auto invariant = MDNode::getDistinct(alloc->getContext(), {});
    CachePointerInvariantGroups[std::make_pair((Value *)root, buffers)] =
        invariant;
    if (allocateInternal) {
      if (shared) {
        group->width = entry.CreateAlloca(i64, nullptr, name + "_groupwidth");
        group->widthStore = entry.CreateStore(entry.getInt64(0), group->width);
      }
      IRBuilder<> init(outer->getTerminator());
      auto before = previousInstruction(init);
      auto size =
          init.CreateAdd(sublimits.back().first, init.getInt64(buffers));
      CallInst *allocation = nullptr;
      Instruction *zero = nullptr;
      auto table = CreateAllocation(
          init, slotType, size,
          name + (shared ? "_groupmalloccache" : "_malloccache"), &allocation,
          EnzymeZeroCache ? &zero : nullptr);
      group->allocations.push_back(allocation);
      auto stored = init.CreateStore(table, root);
      stored->setMetadata(LLVMContext::MD_invariant_group, invariant);
      PostCacheStore(stored, init);
      for (unsigned i = 0; i < buffers; ++i) {
        auto header = init.CreateInBoundsGEP(slotType, table, init.getInt64(i));
        init.CreateStore(Constant::getNullValue(slotType), header);
      }
      recordCacheInstructions(owner, init, before);

      // Each level appends to one contiguous buffer, recording the start in
      // its parent's offset table. Intermediate buffers hold offsets only.
      for (unsigned level = buffers; level-- > 0;) {
        auto used = entry.CreateAlloca(
            i64, nullptr, name + (shared ? "_groupused" : "_used"));
        auto capacity = entry.CreateAlloca(
            i64, nullptr, name + (shared ? "_groupcapacity" : "_capacity"));
        if (owner) {
          scopeInstructions[owner].push_back(used);
          scopeInstructions[owner].push_back(capacity);
        }
        before = previousInstruction(init);
        init.CreateStore(init.getInt64(0), used);
        init.CreateStore(init.getInt64(0), capacity);
        recordCacheInstructions(owner, init, before);
        IRBuilder<> B(
            sublimits[level].second.back().first.preheader->getTerminator());
        SmallVector<Value *, 4> indices;
        ValueToValueMapTy available;
        for (unsigned j = buffers; j > level; --j)
          indices.push_back(
              computeIndexOfChunk(true, B, sublimits[j].second, available));
        Value *extent = sublimits[level].first;
        if (level == 0 && extraSize) {
          for (const auto &chunk : sublimits)
            for (const auto &loop : chunk.second)
              if (auto var = loop.first.var)
                available[var] = var;
          auto extra = unwrapM(extraSize, B, available,
                               UnwrapMode::AttemptFullUnwrapWithLookup);
          assert(extra);
          extent = B.CreateNUWMul(extent, extra);
        }
        before = previousInstruction(B);
        auto base = B.CreateLoad(rootType, root);
        auto slot = packedSlot(B, base, slotType, buffers, indices);
        auto header = B.CreateInBoundsGEP(slotType, base, B.getInt64(level));
        auto buffer = B.CreateLoad(slotType, header);
        auto offset = B.CreateLoad(i64, used);
        auto old = B.CreateLoad(i64, capacity);
        Value *stride = slotBytes;
        Type *element = i64;
        if (level == 0) {
          element = types.front();
          stride = B.getInt64(DL.getTypeAllocSize(element));
          if (shared)
            stride = B.CreateNUWMul(stride, B.CreateLoad(i64, group->width));
        }
        auto required = B.CreateNUWAdd(offset, extent);
        auto doubled = B.CreateShl(old, 1);
        auto canDouble = B.CreateICmpULE(
            old, B.CreateUDiv(B.getInt64(UINT64_MAX / 2), stride));
        doubled = B.CreateSelect(canDouble, doubled, required);
        auto larger = B.CreateSelect(B.CreateICmpUGT(required, doubled),
                                     required, doubled);
        auto next = B.CreateSelect(B.CreateICmpUGT(required, old), larger, old);
        auto ptr = B.CreatePointerCast(buffer, rawPtr);
        auto grown = B.CreateCall(
            getRaggedCacheGrower(*newFunc->getParent(), rawPtr, element,
                                 EnzymeZeroCache),
            {ptr, B.CreateNUWMul(old, stride), B.CreateNUWMul(next, stride)},
            name + (shared ? "_groupgrowcache" : "_growcache"));
        group->allocations.push_back(grown);
        B.CreateStore(B.CreatePointerCast(grown, slotType), header);
        B.CreateStore(next, capacity);
        B.CreateStore(required, used);
        auto saved = B.CreateStore(B.CreateIntToPtr(offset, slotType), slot);
        saved->setMetadata(LLVMContext::MD_invariant_group,
                           MDNode::getDistinct(alloc->getContext(), {}));
        recordCacheInstructions(owner, B, before);
      }
    }

    auto free = shouldFree
                    ? freeCache(outer, sublimits, buffers, root, rootType,
                                slotBytes, root, invariant, slotType)
                    : nullptr;
    if (allocateInternal || free) {
      auto ident = MDNode::getDistinct(
          alloc->getContext(),
          {ConstantAsMetadata::get(entry.getInt1(allocateInternal && free))});
      auto tag = MDNode::get(alloc->getContext(), {ident});
      if (allocateInternal)
        group->allocations.front()->setMetadata("enzyme_cache_alloc", tag);
      if (free)
        free->setMetadata("enzyme_cache_free", tag);
    }
  }

  scopeAllocs[alloc].append(group->allocations.begin(),
                            group->allocations.end());
  if (shared) {
    packedCacheFields[alloc] = PackedCacheField{group->width, group->fields++};
    group->widthStore->setOperand(0, entry.getInt64(group->fields));
    IRBuilder<> B(outer->getTerminator());
    auto before = previousInstruction(B);
    B.CreateStore(B.CreateLoad(rootType, group->table), alloc);
    recordCacheInstructions(alloc, B, before);
  }
}

/// Caching mechanism: creates a cache of type T in a scope given by ctx
/// (where if ctx is in a loop there will be a corresponding number of slots)
AllocaInst *CacheUtility::createCacheForScope(LimitContext ctx, Type *T,
                                              StringRef name, bool shouldFree,
                                              bool allocateInternal,
                                              Value *extraSize) {
  assert(ctx.Block);
  assert(T);

  auto sublimits =
      getSubLimits(/*inForwardPass*/ true, nullptr, ctx, extraSize);

  auto i64 = Type::getInt64Ty(T->getContext());

  auto layout = getCacheLayout(*newFunc, T, sublimits);
  const auto &types = layout.types;

  // Allocate the outermost type on the stack
  IRBuilder<> entryBuilder(inversionAllocs);
  entryBuilder.setFastMathFlags(getFast());
  AllocaInst *alloc =
      entryBuilder.CreateAlloca(types.back(), nullptr, name + "_cache");
  {
    ConstantInt *byteSizeOfType = ConstantInt::get(
        i64, newFunc->getParent()->getDataLayout().getTypeAllocSizeInBits(
                 types.back()) /
                 8);
    unsigned align =
        getCacheAlignment((unsigned)byteSizeOfType->getZExtValue());
    alloc->setAlignment(Align(align));
  }
  auto undef_v = getUndefinedValueForType(*newFunc->getParent(), types.back(),
                                          /*forceZero*/ false);
  if (!isa<UndefValue>(undef_v))
    scopeInstructions[alloc].push_back(
        entryBuilder.CreateStore(undef_v, alloc));

  if (EnzymePrintPerf && sublimits.size() >= 2)
    errs() << "Ragged cache " << name << ": " << *T << ", " << sublimits.size()
           << " chunks, " << (layout.packed ? "packed" : "unpacked") << "\n";
  if (layout.packed) {
    createPackedCache(alloc, sublimits, types, layout.mallocTypes[0], name,
                      shouldFree, allocateInternal, extraSize);
    return alloc;
  }

  Value *storeInto = alloc;
  // Iterating from outermost chunk to innermost chunk
  // Allocate and store the requisite memory if needed
  // and lookup the next level pointer of the cache
  for (int i = sublimits.size() - 1; i >= 0; i--) {
    const auto &containedloops = sublimits[i].second;

    Type *myType = types[i];

    ConstantInt *byteSizeOfType = ConstantInt::get(
        Type::getInt64Ty(T->getContext()),
        newFunc->getParent()->getDataLayout().getTypeAllocSizeInBits(myType) /
            8);

    unsigned bsize = (unsigned)byteSizeOfType->getZExtValue();
    unsigned alignSize = getCacheAlignment(bsize);

    CallInst *malloccall = nullptr;

    // Allocate and store the required memory
    if (allocateInternal) {

      IRBuilder<> allocationBuilder(
          &containedloops.back().first.preheader->back());

      Value *size = sublimits[i].first;
      if (EfficientBoolCache && T->isIntegerTy(1) && i == 0) {
        size = allocationBuilder.CreateLShr(
            allocationBuilder.CreateAdd(
                size, ConstantInt::get(Type::getInt64Ty(T->getContext()), 7),
                "", true),
            ConstantInt::get(Type::getInt64Ty(T->getContext()), 3));
      }
      if (extraSize && i == 0) {
        ValueToValueMapTy available;
        for (auto &sl : sublimits) {
          for (auto &cl : sl.second) {
            if (cl.first.var)
              available[cl.first.var] = cl.first.var;
          }
        }
        Value *es = unwrapM(extraSize, allocationBuilder, available,
                            UnwrapMode::AttemptFullUnwrapWithLookup);
        assert(es);
        size = allocationBuilder.CreateMul(size, es, "", /*NUW*/ true,
                                           /*NSW*/ true);
      }

      StoreInst *storealloc = nullptr;
      // Statically allocate memory for all iterations if possible
      if (sublimits[i].second.back().first.maxLimit) {
        Instruction *ZeroInst = nullptr;
        auto firstallocation = CreateAllocation(
            allocationBuilder, myType, size, name + "_malloccache", &malloccall,
            /*ZeroMem*/ EnzymeZeroCache ? &ZeroInst : nullptr);

        if (malloccall) {
          auto ident = MDNode::getDistinct(
              malloccall->getContext(),
              {ConstantAsMetadata::get(
                  ConstantInt::getFalse(malloccall->getContext()))});
          malloccall->setMetadata(
              "enzyme_cache_alloc",
              MDNode::get(malloccall->getContext(), {ident}));
          // Only caches of numbers may share a tape arena chunk: a nested
          // derivative's type analysis must not see pointers and numbers at
          // the same unknown offsets of one allocation.
          if (isCallerOwnedCacheElement(myType))
            malloccall->setMetadata(
                "enzyme_cache_pointer_free",
                MDNode::get(malloccall->getContext(), {}));
        }

        scopeInstructions[alloc].push_back(malloccall);
        if (firstallocation != malloccall)
          scopeInstructions[alloc].push_back(
              cast<Instruction>(firstallocation));

        for (auto &actx : sublimits[i].second) {
          if (actx.first.offset) {
            malloccall->setMetadata("enzyme_ompfor",
                                    MDNode::get(malloccall->getContext(), {}));
            break;
          }
        }

        if (ZeroInst) {
          if (ZeroInst->getOperand(0) != malloccall) {
            scopeInstructions[alloc].push_back(
                cast<Instruction>(ZeroInst->getOperand(0)));
          }
          scopeInstructions[alloc].push_back(ZeroInst);
        }
        storealloc = allocationBuilder.CreateStore(firstallocation, storeInto);

        scopeAllocs[alloc].push_back(malloccall);

        // Mark the store as invariant since the allocation is static and
        // will not be changed
        if (CachePointerInvariantGroups.find(std::make_pair(
                (Value *)alloc, i)) == CachePointerInvariantGroups.end()) {
          MDNode *invgroup = MDNode::getDistinct(alloc->getContext(), {});
          CachePointerInvariantGroups[std::make_pair((Value *)alloc, i)] =
              invgroup;
        }
        storealloc->setMetadata(
            LLVMContext::MD_invariant_group,
            CachePointerInvariantGroups[std::make_pair((Value *)alloc, i)]);
        scopeInstructions[alloc].push_back(storealloc);
        for (auto post : PostCacheStore(storealloc, allocationBuilder)) {
          scopeInstructions[alloc].push_back(post);
        }
      } else {
        llvm::PointerType *allocType = cast<PointerType>(types[i + 1]);
        llvm::PointerType *mallocType = layout.mallocTypes[i];

        // Reallocate memory dynamically as a fallback
        // TODO change this to a power-of-two allocation strategy

        auto zerostore = allocationBuilder.CreateStore(
            getUndefinedValueForType(*newFunc->getParent(), allocType,
                                     /*forceZero*/ true),
            storeInto);
        scopeInstructions[alloc].push_back(zerostore);

        IRBuilder<> build(containedloops.back().first.incvar->getNextNode());
        Value *allocation = build.CreateLoad(allocType, storeInto);

        if (allocation->getType() != mallocType) {
          auto I =
              cast<Instruction>(build.CreateBitCast(allocation, mallocType));
          scopeInstructions[alloc].push_back(I);
          allocation = I;
        }

        CallInst *realloccall = nullptr;
        auto reallocation = CreateReAllocation(
            build, allocation, myType, containedloops.back().first.incvar, size,
            name + "_realloccache", &realloccall, EnzymeZeroCache && i == 0);

        scopeInstructions[alloc].push_back(cast<Instruction>(reallocation));

        if (reallocation->getType() != allocType) {
          auto I =
              cast<Instruction>(build.CreateBitCast(reallocation, allocType));
          scopeInstructions[alloc].push_back(I);
          reallocation = I;
        }

        scopeAllocs[alloc].push_back(realloccall);

        storealloc = build.CreateStore(reallocation, storeInto);
        // Unlike the static case we can not mark the memory as invariant
        // since we are reloading/storing based off the number of loop
        // iterations
        scopeInstructions[alloc].push_back(storealloc);
        for (auto post : PostCacheStore(storealloc, build)) {
          scopeInstructions[alloc].push_back(post);
        }
      }

      // Regardless of how allocated (dynamic vs static), mark it
      // as having the requisite alignment
      storealloc->setAlignment(Align(alignSize));
    }

    // Free the memory, if requested
    if (shouldFree) {
      if (CachePointerInvariantGroups.find(std::make_pair((Value *)alloc, i)) ==
          CachePointerInvariantGroups.end()) {
        MDNode *invgroup = MDNode::getDistinct(alloc->getContext(), {});
        CachePointerInvariantGroups[std::make_pair((Value *)alloc, i)] =
            invgroup;
      }
      Type *nextType = types[i + 1];
      auto freecall = freeCache(
          containedloops.back().first.preheader, sublimits, i, alloc, nextType,
          byteSizeOfType, storeInto,
          CachePointerInvariantGroups[std::make_pair((Value *)alloc, i)]);
      if (freecall) {
        auto ident =
            MDNode::getDistinct(freecall->getContext(),
                                {ConstantAsMetadata::get(ConstantInt::getFalse(
                                    freecall->getContext()))});
        freecall->setMetadata("enzyme_cache_free",
                              MDNode::get(freecall->getContext(), {ident}));
      }
      if (freecall && malloccall) {
        auto ident =
            MDNode::getDistinct(freecall->getContext(),
                                {ConstantAsMetadata::get(ConstantInt::getTrue(
                                    freecall->getContext()))});
        malloccall->setMetadata("enzyme_cache_alloc",
                                MDNode::get(malloccall->getContext(), {ident}));
        freecall->setMetadata("enzyme_cache_free",
                              MDNode::get(freecall->getContext(), {ident}));
      }
    }

    // If we are not the final iteration, lookup the next pointer by indexing
    // into the relevant location of the current chunk allocation
    if (i != 0) {
      IRBuilder<> v(&sublimits[i - 1].second.back().first.preheader->back());

      Value *idx = computeIndexOfChunk(
          /*inForwardPass*/ true, v, containedloops,
          /*available*/ ValueToValueMapTy());

      storeInto = v.CreateLoad(types[i + 1], storeInto);
      cast<LoadInst>(storeInto)->setAlignment(Align(alignSize));
      storeInto = v.CreateInBoundsGEP(types[i], storeInto, idx);
    }
  }
  return alloc;
}

Value *CacheUtility::computeIndexOfChunk(
    bool inForwardPass, IRBuilder<> &v,
    ArrayRef<std::pair<LoopContext, llvm::Value *>> containedloops,
    const ValueToValueMapTy &available) {
  // List of loop indices in chunk from innermost to outermost
  SmallVector<Value *, 3> indices;
  // List of cumulative indices in chunk from innermost to outermost
  // where limit[i] = prod(loop limit[0..i])
  SmallVector<Value *, 3> limits;

  // Iterate from innermost loop to outermost loop within a chunk
  for (size_t i = 0; i < containedloops.size(); ++i) {
    const auto &pair = containedloops[i];

    const auto &idx = pair.first;
    Value *var = idx.var;

    // In the SingleIteration, var may be null (since there's no legal phinode)
    // In that case the current iteration is simply the constnat Zero
    if (idx.var == nullptr)
      var = ConstantInt::get(Type::getInt64Ty(newFunc->getContext()), 0);
    else if (available.count(var)) {
      var = available.find(var)->second;
    } else if (!inForwardPass) {
      var = v.CreateLoad(idx.var->getType(), idx.antivaralloc);
    } else {
      var = idx.var;
    }
    if (idx.offset) {
      var = v.CreateAdd(var, lookupM(idx.offset, v), "", /*NUW*/ true,
                        /*NSW*/ true);
    }

    indices.push_back(var);
    Value *lim = pair.second;
    assert(lim);
    if (limits.size() == 0) {
      limits.push_back(lim);
    } else {
      limits.push_back(v.CreateMul(limits.back(), lim, "",
                                   /*NUW*/ true, /*NSW*/ true));
    }
  }

  assert(indices.size() > 0);

  // Compute the index into the pointer
  Value *idx = indices[0];
  for (unsigned ind = 1; ind < indices.size(); ++ind) {
    idx = v.CreateAdd(idx,
                      v.CreateMul(indices[ind], limits[ind - 1], "",
                                  /*NUW*/ true, /*NSW*/ true),
                      "", /*NUW*/ true, /*NSW*/ true);
  }
  return idx;
}

/// Given a LimitContext ctx, representing a location inside a loop nest,
/// break each of the loops up into chunks of loops where each chunk's number
/// of iterations can be computed at the chunk preheader. Every dynamic loop
/// defines the start of a chunk. SubLimitType is a vector of chunk objects.
/// More specifically it is a vector of { # iters in a Chunk (sublimit), Chunk }
/// Each chunk object is a vector of loops contained within the chunk.
/// For every loop, this returns pair of the LoopContext and the limit of that
/// loop Both the vector of Chunks and vector of Loops within a Chunk go from
/// innermost loop to outermost loop.
CacheUtility::SubLimitType CacheUtility::getSubLimits(bool inForwardPass,
                                                      IRBuilder<> *RB,
                                                      LimitContext ctx,
                                                      Value *extraSize) {
  // Store the LoopContext's in InnerMost => Outermost order
  SmallVector<LoopContext, 4> contexts;

  // Given a ``SingleIteration'' Limit Context, return a chunking of
  // one loop with size 1, and header/preheader of the BasicBlock
  // This is done to create a context for a block outside a loop
  // and is part of an experimental mechanism for merging stores
  // into a unified memcpy
  if (ctx.ForceSingleIteration) {
    LoopContext idx;
    auto subctx = ctx.Block;
    auto zero = ConstantInt::get(Type::getInt64Ty(newFunc->getContext()), 0);
    // The iteration count is always zero so we can set it as such
    idx.var = nullptr; // = zero;
    idx.incvar = nullptr;
    idx.antivaralloc = nullptr;
    idx.trueLimit = zero;
    idx.maxLimit = zero;
    idx.header = subctx;
    idx.preheader = subctx;
    idx.dynamic = false;
    idx.parent = nullptr;
    idx.exitBlocks = {};
    idx.offset = nullptr;
    idx.allocLimit = nullptr;
    contexts.push_back(idx);
  }

  for (BasicBlock *blk = ctx.Block; blk != nullptr;) {
    LoopContext idx;
    if (!getContext(blk, idx, ctx.ReverseLimit)) {
      break;
    }
    contexts.emplace_back(std::move(idx));
    blk = idx.preheader;
  }

  // Legal preheaders for loop i (indexed from inner => outer)
  SmallVector<BasicBlock *, 4> allocationPreheaders(contexts.size(), nullptr);
  // Limit of loop i (indexed from inner => outer)
  SmallVector<Value *, 4> limits(contexts.size(), nullptr);

  // Iterate from outermost loop to innermost loop
  for (int i = contexts.size() - 1; i >= 0; --i) {
    // The outermost loop's preheader is the preheader directly
    // outside the loop nest
    if ((unsigned)i == contexts.size() - 1) {
      allocationPreheaders[i] = contexts[i].preheader;
    } else if (!contexts[i].maxLimit) {
      // For dynamic loops, the preheader is now forced to be the preheader
      // of that loop
      allocationPreheaders[i] = contexts[i].preheader;
    } else {
      // Otherwise try to use the preheader of the loop just outside this
      // one to allocate all iterations across both loops together
      allocationPreheaders[i] = allocationPreheaders[i + 1];
    }

    // Dynamic loops are considered to have a limit of one for allocation
    // purposes This is because we want to allocate 1 x (# of iterations inside
    // chunk) inside every dynamic iteration
    if (!contexts[i].maxLimit) {
      limits[i] =
          ConstantInt::get(Type::getInt64Ty(ctx.Block->getContext()), 1);
    } else {
      // Map of previous induction variables we are allowed to use as part
      // of the computation of the number of iterations in this chunk
      ValueToValueMapTy prevMap;

      // Iterate from outermost loop down
      for (int j = contexts.size() - 1;; --j) {
        // If the preheader allocating memory for loop i
        // is distinct from this preheader, we are therefore allocating
        // memory in a different chunk. We can use induction variables
        // from chunks outside us to compute loop bounds so add it to the
        // map
        if (allocationPreheaders[i] != contexts[j].preheader) {
          prevMap[contexts[j].var] = contexts[j].var;
        } else {
          break;
        }
      }

      IRBuilder<> allocationBuilder(&allocationPreheaders[i]->back());
      Value *limitMinus1 = nullptr;

      Value *limit = contexts[i].maxLimit;
      if (contexts[i].allocLimit)
        limit = contexts[i].allocLimit;

      // Attempt to compute the limit of this loop at the corresponding
      // allocation preheader. This is null if it was not legal to compute
      limitMinus1 = unwrapM(limit, allocationBuilder, prevMap,
                            UnwrapMode::AttemptFullUnwrap);

      // We have a loop with static bounds, but whose limit is not available
      // to be computed at the current loop preheader (such as the innermost
      // loop of triangular iteration domain) Handle this case like a dynamic
      // loop and create a new chunk.
      if (limitMinus1 == nullptr) {
        EmitWarning("NoOuterLimit", *cast<Instruction>(&*limit),
                    "Could not compute outermost loop limit by moving value ",
                    *limit, " computed at block", contexts[i].header->getName(),
                    " function ", contexts[i].header->getParent()->getName());
        // A bound may vary across an outer loop while remaining invariant
        // across several inner loops. Try each boundary within the current
        // chunk before falling back to a separate allocation for this loop.
        int outer = i;
        while (outer + 1 < (int)contexts.size() &&
               allocationPreheaders[outer + 1] == allocationPreheaders[i])
          ++outer;
        for (int candidate = outer - 1; candidate >= i; --candidate) {
          prevMap.clear();
          for (int j = contexts.size() - 1; j > candidate; --j)
            prevMap[contexts[j].var] = contexts[j].var;
          allocationBuilder.SetInsertPoint(
              &contexts[candidate].preheader->back());
          limitMinus1 = unwrapM(limit, allocationBuilder, prevMap,
                                UnwrapMode::AttemptFullUnwrap);
          if (limitMinus1 && candidate > i && i == 0 && extraSize &&
              !unwrapM(extraSize, allocationBuilder, prevMap,
                       UnwrapMode::AttemptFullUnwrap))
            limitMinus1 = nullptr;
          if (limitMinus1) {
            // Split every intervening loop out of the old chunk, so the
            // allocation and all its indices agree on the new boundary.
            for (int j = i; j <= candidate; ++j)
              allocationPreheaders[j] = contexts[candidate].preheader;
            break;
          }
        }
        if (limitMinus1 == nullptr) {
          llvm::errs() << *contexts[i].preheader->getParent() << "\n";
          llvm::errs() << "block: " << *allocationPreheaders[i] << "\n";
          llvm::errs() << "limit: " << *limit << "\n";
        }
        assert(limitMinus1 != nullptr);
      } else if (i == 0 && extraSize &&
                 unwrapM(extraSize, allocationBuilder, prevMap,
                         UnwrapMode::AttemptFullUnwrap) == nullptr) {
        EmitWarning(
            "NoOuterLimit", *cast<Instruction>(extraSize), newFunc,
            cast<Instruction>(extraSize)->getParent(),
            "Could not compute outermost loop limit by moving extraSize value ",
            *extraSize, " computed at block", contexts[i].header->getName(),
            " function ", contexts[i].header->getParent()->getName());
        allocationPreheaders[i] = contexts[i].preheader;
        allocationBuilder.SetInsertPoint(&allocationPreheaders[i]->back());
      }
      assert(limitMinus1 != nullptr);

      ValueToValueMapTy reverseMap;
      // Iterate from outermost loop down
      for (int j = contexts.size() - 1;; --j) {
        // If the preheader allocating memory for loop i
        // is distinct from this preheader, we are therefore allocating
        // memory in a different chunk. We can use induction variables
        // from chunks outside us to compute loop bounds so add it to the
        // map
        if (allocationPreheaders[i] != contexts[j].preheader) {
          if (!inForwardPass) {
            reverseMap[contexts[j].var] = RB->CreateLoad(
                contexts[j].var->getType(), contexts[j].antivaralloc);
          }
        } else {
          break;
        }
      }

      bool canSkipLoop = false;
      if (allocationPreheaders[i] != contexts[i].preheader) {
        for (int k = i; (unsigned)(k + 1) < contexts.size() &&
                        allocationPreheaders[k] != contexts[k].preheader;
             ++k) {
          BasicBlock *cur = contexts[k].preheader;
          while (cur != contexts[k + 1].header) {
            if (cur->getTerminator()->getNumSuccessors() != 1) {
              canSkipLoop = true;
              break;
            }
            cur = cur->getSinglePredecessor();
            if (!cur) {
              canSkipLoop = true;
              break;
            }
          }
          if (cur && cur->getTerminator()->getNumSuccessors() != 1) {
            canSkipLoop = true;
          }
          if (canSkipLoop)
            break;
        }
      }

      // We now need to compute the actual limit as opposed to the limit
      // minus one.
      if (inForwardPass) {
        // For efficiency, avoid doing this multiple times for
        // the same <limitMinus1, Block requested at> pair by caching inside
        // of LimitCache.
        auto &map = LimitCache[limitMinus1];
        auto found = map.find(allocationPreheaders[i]);
        if (found != map.end() && found->second != nullptr) {
          limits[i] = found->second;
        } else {
          Value *add = allocationBuilder.CreateNSWAdd(
              limitMinus1, ConstantInt::get(limitMinus1->getType(), 1));
          if (canSkipLoop) {
            auto zero = ConstantInt::get(limitMinus1->getType(), 0);
            add = allocationBuilder.CreateSelect(
                allocationBuilder.CreateICmpSLT(add, zero), zero, add);
          }
          limits[i] = map[allocationPreheaders[i]] = add;
        }
      } else {
        Value *lim = unwrapM(limitMinus1, *RB, reverseMap,
                             UnwrapMode::AttemptFullUnwrapWithLookup,
                             allocationPreheaders[i]);
        if (!lim) {
          llvm::errs() << *newFunc << "\n";
          llvm::errs() << *limitMinus1 << "\n";
        }
        assert(lim);
        Value *add = RB->CreateNSWAdd(lim, ConstantInt::get(lim->getType(), 1));
        if (canSkipLoop) {
          auto zero = ConstantInt::get(lim->getType(), 0);
          add = RB->CreateSelect(RB->CreateICmpSLT(add, zero), zero, add);
        }
        limits[i] = add;
      }
    }
  }

  SubLimitType sublimits;

  // Total number of iterations of current chunk of loops
  Value *size = nullptr;
  // Loops inside current chunk (stored innermost to outermost)
  SmallVector<std::pair<LoopContext, Value *>, 3> lims;

  // Iterate from innermost to outermost loops
  for (unsigned i = 0; i < contexts.size(); ++i) {
    IRBuilder<> allocationBuilder(&allocationPreheaders[i]->back());
    lims.push_back(std::make_pair(contexts[i], limits[i]));
    // Compute the cumulative size
    if (size == nullptr) {
      // If starting with no cumulative size, this is the cumulative size
      size = limits[i];
    } else if (!inForwardPass) {
      size = RB->CreateMul(size, limits[i], "",
                           /*NUW*/ true, /*NSW*/ true);
    } else {
      // Otherwise new size = old size * limits[i];
      auto cidx = std::make_tuple(size, limits[i], allocationPreheaders[i]);
      if (SizeCache.find(cidx) == SizeCache.end()) {
        SizeCache[cidx] =
            allocationBuilder.CreateMul(size, limits[i], "",
                                        /*NUW*/ true, /*NSW*/ true);
      }
      size = SizeCache[cidx];
    }

    // If we are starting a new chunk in the next iteration
    // push this chunk to sublimits and clear the cumulative calculations
    if ((i + 1 < contexts.size()) &&
        (allocationPreheaders[i] != allocationPreheaders[i + 1])) {
      sublimits.push_back(std::make_pair(size, lims));
      size = nullptr;
      lims.clear();
    }
  }

  // For any remaining loop chunks, add them to the list
  if (size != nullptr) {
    sublimits.push_back(std::make_pair(size, lims));
    lims.clear();
  }

  return sublimits;
}

/// Given an allocation defined at a particular ctx, store the value val
/// in the cache at the location defined in the given builder
void CacheUtility::storeInstructionInCache(LimitContext ctx,
                                           IRBuilder<> &BuilderM, Value *val,
                                           AllocaInst *cache, MDNode *TBAA) {
  assert(BuilderM.GetInsertBlock()->getParent() == newFunc);
#ifndef NDEBUG
  if (auto inst = dyn_cast<Instruction>(val))
    assert(inst->getParent()->getParent() == newFunc);
#endif
  IRBuilder<> v(BuilderM.GetInsertBlock());
  v.SetInsertPoint(BuilderM.GetInsertBlock(), BuilderM.GetInsertPoint());
  v.setFastMathFlags(getFast());

  // Note for dynamic loops where the allocation is stored somewhere inside
  // the loop, we must ensure that we load the allocation after actually
  // storing the allocation itself.
  // To simplify things and ensure we always store after a
  // potential realloc occurs in this loop, we put our store after
  // any existing stores in the loop.
  // This is okay as there should be no load to the cache in the same block
  // where this instruction is defined as we will just use this instruction
  // TODO check that the store is actually aliasing/related
  if (BuilderM.GetInsertPoint() != BuilderM.GetInsertBlock()->end()) {
    for (auto I = BuilderM.GetInsertBlock()->rbegin(),
              E = BuilderM.GetInsertBlock()->rend();
         I != E; ++I) {
      if (&*I == &*BuilderM.GetInsertPoint())
        break;
      if (auto si = dyn_cast<StoreInst>(&*I)) {
        auto ni = getNextNonDebugInstructionOrNull(si);
        if (ni != nullptr) {
          v.SetInsertPoint(ni);
        } else {
          v.SetInsertPoint(si->getParent());
        }
      }
    }
  }

  Type *storageType = nullptr;
  Value *bitIndex = nullptr;
  Value *loc =
      getCachePointer(val->getType(), true, v, ctx, cache, true,
                      ValueToValueMapTy(), nullptr, &storageType, &bitIndex);
  auto before = previousInstruction(v);
  Value *tostore = val;
  if (val->getType() != storageType)
    tostore = v.CreateZExt(val, storageType);
  if (bitIndex) {
    auto shift =
        v.CreateTrunc(v.CreateAnd(bitIndex, v.getInt64(7)), storageType);
    auto mask = v.CreateNot(v.CreateShl(v.getInt8(1), shift));
    auto previous = v.CreateLoad(storageType, loc);
    tostore =
        v.CreateOr(v.CreateAnd(previous, mask), v.CreateShl(tostore, shift));
  }
  recordCacheInstructions(cache, v, before);

#if LLVM_VERSION_MAJOR < 17
  if (tostore->getContext().supportsTypedPointers()) {
    if (tostore->getType() != loc->getType()->getPointerElementType()) {
      llvm::errs() << "val: " << *val << "\n";
      llvm::errs() << "tostore: " << *tostore << "\n";
      llvm::errs() << "loc: " << *loc << "\n";
    }
    assert(tostore->getType() == loc->getType()->getPointerElementType());
  }
#endif

  StoreInst *storeinst = v.CreateStore(tostore, loc);

  // If the value stored doesnt change (per efficient bool cache),
  // mark it as invariant
  if (tostore == val) {
    if (ValueInvariantGroups.find(cache) == ValueInvariantGroups.end()) {
      MDNode *invgroup = MDNode::getDistinct(cache->getContext(), {});
      ValueInvariantGroups[cache] = invgroup;
    }
    storeinst->setMetadata(LLVMContext::MD_invariant_group,
                           ValueInvariantGroups[cache]);
  }

  // Set alignment
  ConstantInt *byteSizeOfType =
      ConstantInt::get(Type::getInt64Ty(cache->getContext()),
                       ctx.Block->getParent()
                               ->getParent()
                               ->getDataLayout()
                               .getTypeAllocSizeInBits(val->getType()) /
                           8);
  unsigned align = getCacheAlignment((unsigned)byteSizeOfType->getZExtValue());
  storeinst->setMetadata(LLVMContext::MD_tbaa, TBAA);
  storeinst->setAlignment(Align(align));
  scopeInstructions[cache].push_back(storeinst);
  for (auto post : PostCacheStore(storeinst, v)) {
    scopeInstructions[cache].push_back(post);
  }
}

/// Given an allocation defined at a particular ctx, store the instruction
/// in the cache right after the instruction is executed
void CacheUtility::storeInstructionInCache(LimitContext ctx,
                                           llvm::Instruction *inst,
                                           llvm::AllocaInst *cache,
                                           llvm::MDNode *TBAA) {
  assert(ctx.Block);
  assert(inst);
  assert(cache);

  // Find the correct place to issue the store
  IRBuilder<> v(inst->getParent());
  // If this is a PHINode, we need to store after all phinodes,
  // otherwise just after inst sufficies
  if (&*inst->getParent()->rbegin() != inst) {
    Instruction *putafter =
        getFirstNonPHIOrPlaceholder(getNextNonDebugInstruction(inst));
    assert(putafter && "expected an instruction after the cached value");
    v.SetInsertPoint(putafter);
  }
  v.setFastMathFlags(getFast());
  storeInstructionInCache(ctx, v, inst, cache, TBAA);
}

/// Given an allocation specified by the LimitContext ctx and cache, compute a
/// pointer that can hold the underlying type being cached. This value should be
/// computed at BuilderM. Optionally, instructions needed to generate this
/// pointer can be stored in scopeInstructions
Value *CacheUtility::getCachePointer(llvm::Type *T, bool inForwardPass,
                                     IRBuilder<> &BuilderM, LimitContext ctx,
                                     Value *cache, bool storeInInstructionsMap,
                                     const ValueToValueMapTy &available,
                                     Value *extraSize, Type **storageType,
                                     Value **bitIndex) {
  assert(ctx.Block);
  assert(cache);
  auto sublimits = getSubLimits(inForwardPass, &BuilderM, ctx, extraSize);

  Value *next = cache;
  assert(next->getType()->isPointerTy());

  auto layout = getCacheLayout(*newFunc, T, sublimits);
  const auto &types = layout.types;
  auto i64 = BuilderM.getInt64Ty();

  if (storageType)
    *storageType = types.front();
  if (layout.packed) {
    unsigned buffers = sublimits.size() - 1;
    auto slotType = types[buffers];
    SmallVector<Value *, 4> indices;
    for (unsigned i = buffers; i > 0; --i)
      indices.push_back(computeIndexOfChunk(inForwardPass, BuilderM,
                                            sublimits[i].second, available));
    auto inner = computeIndexOfChunk(inForwardPass, BuilderM,
                                     sublimits[0].second, available);
    if (extraSize)
      inner = BuilderM.CreateNUWMul(inner, lookupM(extraSize, BuilderM));
    auto before = previousInstruction(BuilderM);
    auto table = BuilderM.CreateLoad(types.back(), cache);
    auto slot = packedSlot(BuilderM, table, slotType, buffers, indices);
    auto offset =
        BuilderM.CreatePtrToInt(BuilderM.CreateLoad(slotType, slot), i64);
    auto buffer = BuilderM.CreatePointerCast(
        BuilderM.CreateLoad(slotType, table), types[1]);
    auto index = BuilderM.CreateNUWAdd(offset, inner);
    auto AI = dyn_cast<AllocaInst>(cache);
    auto field = packedCacheFields.find(AI);
    if (field != packedCacheFields.end()) {
      auto width = BuilderM.CreateLoad(i64, field->second.width);
      index = BuilderM.CreateNUWAdd(BuilderM.CreateNUWMul(index, width),
                                    BuilderM.getInt64(field->second.index));
    }
    auto result = BuilderM.CreateInBoundsGEP(types.front(), buffer, index);
    recordCacheInstructions(storeInInstructionsMap ? AI : nullptr, BuilderM,
                            before);
    return result;
  }

  // Iterate from outermost loop to innermost loop
  for (int i = sublimits.size() - 1; i >= 0; i--) {
    // Lookup the next allocation pointer
    next = BuilderM.CreateLoad(types[i + 1], next);
    if (storeInInstructionsMap && isa<AllocaInst>(cache))
      scopeInstructions[cast<AllocaInst>(cache)].push_back(
          cast<Instruction>(next));

    if (!next->getType()->isPointerTy()) {
      llvm::errs() << *newFunc << "\n";
      llvm::errs() << "cache: " << *cache << "\n";
      llvm::errs() << "next: " << *next << "\n";
      assert(next->getType()->isPointerTy());
    }

    // Set appropriate invairant lookup flags
    if (CachePointerInvariantGroups.find(std::make_pair(cache, i)) ==
        CachePointerInvariantGroups.end()) {
      MDNode *invgroup = MDNode::getDistinct(cache->getContext(), {});
      CachePointerInvariantGroups[std::make_pair(cache, i)] = invgroup;
    }
    cast<LoadInst>(next)->setMetadata(
        LLVMContext::MD_invariant_group,
        CachePointerInvariantGroups[std::make_pair(cache, i)]);

    // Set dereferenceable and alignment flags
    ConstantInt *byteSizeOfType = ConstantInt::get(
        Type::getInt64Ty(cache->getContext()),
        newFunc->getParent()->getDataLayout().getTypeAllocSizeInBits(
            next->getType()) /
            8);
    cast<LoadInst>(next)->setMetadata(
        LLVMContext::MD_dereferenceable,
        MDNode::get(
            cache->getContext(),
            ArrayRef<Metadata *>(ConstantAsMetadata::get(byteSizeOfType))));
    unsigned align =
        getCacheAlignment((unsigned)byteSizeOfType->getZExtValue());
    cast<LoadInst>(next)->setAlignment(Align(align));

    const auto &containedloops = sublimits[i].second;

    if (containedloops.size() > 0) {
      Value *idx = computeIndexOfChunk(inForwardPass, BuilderM, containedloops,
                                       available);
      if (EfficientBoolCache && T->isIntegerTy(1) && i == 0) {
        if (bitIndex)
          *bitIndex = idx;
        idx = BuilderM.CreateLShr(
            idx, ConstantInt::get(Type::getInt64Ty(newFunc->getContext()), 3));
      }
      if (i == 0 && extraSize) {
        Value *es = lookupM(extraSize, BuilderM);
        assert(es);
        idx = BuilderM.CreateMul(idx, es, "", /*NUW*/ true, /*NSW*/ true);
      }
      next = BuilderM.CreateInBoundsGEP(types[i], next, idx);
      if (storeInInstructionsMap && isa<AllocaInst>(cache))
        scopeInstructions[cast<AllocaInst>(cache)].push_back(
            cast<Instruction>(next));
    }
    assert(next->getType()->isPointerTy());
  }
  return next;
}

/// Perform the final load from the cache, applying requisite invariant
/// group and alignment
llvm::Value *CacheUtility::loadFromCachePointer(Type *T,
                                                llvm::IRBuilder<> &BuilderM,
                                                llvm::Value *cptr,
                                                llvm::Value *cache) {
  // Retrieve the actual result
  auto result = BuilderM.CreateLoad(T, cptr);

  // Apply requisite invariant, alignment, etc
  if (ValueInvariantGroups.find(cache) == ValueInvariantGroups.end()) {
    MDNode *invgroup = MDNode::getDistinct(cache->getContext(), {});
    ValueInvariantGroups[cache] = invgroup;
  }
  CacheLookups.insert(result);
  result->setMetadata(LLVMContext::MD_invariant_group,
                      ValueInvariantGroups[cache]);
  ConstantInt *byteSizeOfType = ConstantInt::get(
      Type::getInt64Ty(cache->getContext()),
      newFunc->getParent()->getDataLayout().getTypeAllocSizeInBits(
          result->getType()) /
          8);
  unsigned align = getCacheAlignment((unsigned)byteSizeOfType->getZExtValue());
  result->setAlignment(Align(align));

  return result;
}

/// Given an allocation specified by the LimitContext ctx and cache, lookup the
/// underlying cached value.
Value *CacheUtility::lookupValueFromCache(
    Type *T, bool inForwardPass, IRBuilder<> &BuilderM, LimitContext ctx,
    Value *cache, bool isi1, const ValueToValueMapTy &available,
    Value *extraSize, Value *extraOffset) {
  Type *storageType = nullptr;
  Value *bitIndex = nullptr;
  auto cptr = getCachePointer(T, inForwardPass, BuilderM, ctx, cache, false,
                              available, extraSize, &storageType, &bitIndex);
  if (extraOffset)
    cptr = BuilderM.CreateInBoundsGEP(storageType, cptr, extraOffset);
  Value *result = loadFromCachePointer(storageType, BuilderM, cptr, cache);
  if (bitIndex) {
    auto shift = BuilderM.CreateTrunc(
        BuilderM.CreateAnd(bitIndex, BuilderM.getInt64(7)), storageType);
    result = BuilderM.CreateLShr(result, shift);
  }
  return isi1 ? BuilderM.CreateTruncOrBitCast(result, BuilderM.getInt1Ty())
              : result;
}
