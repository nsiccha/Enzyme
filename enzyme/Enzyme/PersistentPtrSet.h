//===- PersistentPtrSet.h - A pointer set with constant-time copies -------===//
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
// This file contains a set of pointers whose copies share their structure. A
// copy takes constant time and is an independent snapshot: changing either
// side copies only the path to what changed. Walking the elements of one set
// that are missing from another skips whatever the two still share, so its cost
// follows the size of their difference rather than the size of the sets.
//
// It is a hash array mapped trie over a bijective mix of the pointer's bits, so
// two distinct pointers always separate and no collision nodes are needed.
// Reference counts are not atomic: a set and its copies belong to one thread.
//
//===----------------------------------------------------------------------===//
#ifndef ENZYME_PERSISTENT_PTR_SET_H
#define ENZYME_PERSISTENT_PTR_SET_H 1

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <utility>

#include "llvm/Config/llvm-config.h"
#include "llvm/Support/MathExtras.h"
#include "llvm/Support/MemAlloc.h"
#if LLVM_VERSION_MAJOR >= 16
#include "llvm/ADT/bit.h"
#endif

namespace enzyme_detail {

class PersistentPtrTrie {
public:
  struct Node {
    uint32_t RefCount;
    /// Which of the 32 slices of this level hold a slot.
    uint32_t Bitmap;
    /// One entry per set bit of Bitmap, in bit order. An entry is a key, or a
    /// child node with its lowest bit set; keys are aligned, so that bit is
    /// free.
    uintptr_t Slots[1];
  };

  static constexpr unsigned BitsPerLevel = 5;

  static unsigned popcount(uint32_t X) {
#if LLVM_VERSION_MAJOR >= 16
    return llvm::popcount(X);
#else
    return llvm::countPopulation(X);
#endif
  }

  /// A bijection, so that distinct keys have distinct hashes.
  static uint64_t mix(uintptr_t Key) {
    uint64_t X = Key;
    X ^= X >> 33;
    X *= 0xff51afd7ed558ccdULL;
    X ^= X >> 33;
    return X;
  }

  static uint32_t sliceBit(uint64_t Hash, unsigned Shift) {
    assert(Shift < 64);
    return uint32_t(1) << ((Hash >> Shift) & 31);
  }
  static unsigned numSlots(const Node *N) { return popcount(N->Bitmap); }
  static unsigned slotIndex(const Node *N, uint32_t Bit) {
    return popcount(N->Bitmap & (Bit - 1));
  }
  static bool isChild(uintptr_t Slot) { return Slot & 1; }
  static Node *asChild(uintptr_t Slot) {
    return reinterpret_cast<Node *>(Slot & ~uintptr_t(1));
  }
  static uintptr_t fromChild(Node *N) {
    return reinterpret_cast<uintptr_t>(N) | 1;
  }

  static Node *allocate(unsigned Slots, uint32_t Bitmap) {
    size_t Bytes = offsetof(Node, Slots) + sizeof(uintptr_t) * Slots;
    auto *N = static_cast<Node *>(llvm::safe_malloc(Bytes));
    N->RefCount = 1;
    N->Bitmap = Bitmap;
    return N;
  }

  static void retain(Node *N) {
    if (N)
      ++N->RefCount;
  }

  static void release(Node *N) {
    if (!N || --N->RefCount != 0)
      return;
    for (unsigned I = 0, E = numSlots(N); I != E; ++I)
      if (isChild(N->Slots[I]))
        release(asChild(N->Slots[I]));
    std::free(N);
  }

  /// Takes over the caller's reference to N, and returns a node with the same
  /// contents that the caller alone refers to.
  static Node *makeUnique(Node *N) {
    if (N->RefCount == 1)
      return N;
    unsigned Size = numSlots(N);
    Node *R = allocate(Size, N->Bitmap);
    for (unsigned I = 0; I != Size; ++I) {
      R->Slots[I] = N->Slots[I];
      if (isChild(R->Slots[I]))
        retain(asChild(R->Slots[I]));
    }
    --N->RefCount;
    return R;
  }

  /// Takes over the caller's reference to N, whose contents have been copied
  /// into another node: that node now holds N's references to its children.
  static void moveChildrenOut(Node *N) {
    if (N->RefCount == 1) {
      std::free(N);
      return;
    }
    for (unsigned I = 0, E = numSlots(N); I != E; ++I)
      if (isChild(N->Slots[I]))
        retain(asChild(N->Slots[I]));
    --N->RefCount;
  }

  static bool contains(const Node *N, uintptr_t Key, uint64_t Hash,
                       unsigned Shift = 0) {
    while (N) {
      uint32_t Bit = sliceBit(Hash, Shift);
      if (!(N->Bitmap & Bit))
        return false;
      uintptr_t Slot = N->Slots[slotIndex(N, Bit)];
      if (!isChild(Slot))
        return Slot == Key;
      N = asChild(Slot);
      Shift += BitsPerLevel;
    }
    return false;
  }

  static Node *makePair(uintptr_t A, uint64_t HashA, uintptr_t B,
                        uint64_t HashB, unsigned Shift) {
    uint32_t BitA = sliceBit(HashA, Shift), BitB = sliceBit(HashB, Shift);
    if (BitA == BitB) {
      Node *R = allocate(1, BitA);
      R->Slots[0] =
          fromChild(makePair(A, HashA, B, HashB, Shift + BitsPerLevel));
      return R;
    }
    Node *R = allocate(2, BitA | BitB);
    R->Slots[BitA < BitB ? 0 : 1] = A;
    R->Slots[BitA < BitB ? 1 : 0] = B;
    return R;
  }

  /// Adds a key the trie does not hold. Takes over the caller's reference to N
  /// and returns the node to refer to instead.
  static Node *insertAbsent(Node *N, uintptr_t Key, uint64_t Hash,
                            unsigned Shift) {
    uint32_t Bit = sliceBit(Hash, Shift);
    unsigned Index = slotIndex(N, Bit);
    if (!(N->Bitmap & Bit)) {
      unsigned Size = numSlots(N);
      Node *R = allocate(Size + 1, N->Bitmap | Bit);
      for (unsigned I = 0; I != Index; ++I)
        R->Slots[I] = N->Slots[I];
      R->Slots[Index] = Key;
      for (unsigned I = Index; I != Size; ++I)
        R->Slots[I + 1] = N->Slots[I];
      moveChildrenOut(N);
      return R;
    }
    Node *U = makeUnique(N);
    uintptr_t Slot = U->Slots[Index];
    if (isChild(Slot))
      U->Slots[Index] = fromChild(
          insertAbsent(asChild(Slot), Key, Hash, Shift + BitsPerLevel));
    else
      U->Slots[Index] =
          fromChild(makePair(Slot, mix(Slot), Key, Hash, Shift + BitsPerLevel));
    return U;
  }

  /// A copy of the unique node U without the slot at Index, whose reference (if
  /// any) the caller has already dealt with. Consumes U; null if U had no other
  /// slot.
  static Node *withoutSlot(Node *U, uint32_t Bit, unsigned Index) {
    unsigned Size = numSlots(U);
    Node *R = nullptr;
    if (Size != 1) {
      R = allocate(Size - 1, U->Bitmap & ~Bit);
      for (unsigned I = 0; I != Index; ++I)
        R->Slots[I] = U->Slots[I];
      for (unsigned I = Index + 1; I != Size; ++I)
        R->Slots[I - 1] = U->Slots[I];
    }
    std::free(U);
    return R;
  }

  /// Removes a key the trie holds. Takes over the caller's reference to N and
  /// returns the node to refer to instead, or null if nothing remains.
  static Node *erasePresent(Node *N, uintptr_t Key, uint64_t Hash,
                            unsigned Shift) {
    uint32_t Bit = sliceBit(Hash, Shift);
    unsigned Index = slotIndex(N, Bit);
    Node *U = makeUnique(N);
    uintptr_t Slot = U->Slots[Index];
    if (!isChild(Slot)) {
      assert(Slot == Key);
      return withoutSlot(U, Bit, Index);
    }
    Node *Child = erasePresent(asChild(Slot), Key, Hash, Shift + BitsPerLevel);
    if (!Child)
      return withoutSlot(U, Bit, Index);
    U->Slots[Index] = fromChild(Child);
    return U;
  }

  template <typename Fn> static void forEach(const Node *N, Fn &&F) {
    if (!N)
      return;
    for (unsigned I = 0, E = numSlots(N); I != E; ++I) {
      uintptr_t Slot = N->Slots[I];
      if (isChild(Slot))
        forEach(asChild(Slot), F);
      else
        F(Slot);
    }
  }

  /// Calls F for each key under A that is not under B, skipping every node they
  /// share.
  template <typename Fn>
  static void forEachMissing(const Node *A, const Node *B, unsigned Shift,
                             Fn &&F) {
    if (A == B)
      return;
    if (!B) {
      forEach(A, F);
      return;
    }
    if (!A)
      return;
    unsigned I = 0;
    for (uint32_t Rest = A->Bitmap; Rest; Rest &= Rest - 1, ++I) {
      uintptr_t SlotA = A->Slots[I];
      // The lowest remaining bit is the slice of the I-th slot.
      uint32_t Bit = Rest & (~Rest + 1);
      if (!(B->Bitmap & Bit)) {
        if (isChild(SlotA))
          forEach(asChild(SlotA), F);
        else
          F(SlotA);
        continue;
      }
      uintptr_t SlotB = B->Slots[slotIndex(B, Bit)];
      if (SlotA == SlotB)
        continue;
      if (isChild(SlotA)) {
        if (isChild(SlotB)) {
          forEachMissing(asChild(SlotA), asChild(SlotB), Shift + BitsPerLevel,
                         F);
        } else {
          forEach(asChild(SlotA), [&](uintptr_t Key) {
            if (Key != SlotB)
              F(Key);
          });
        }
      } else if (isChild(SlotB)) {
        if (!contains(asChild(SlotB), SlotA, mix(SlotA), Shift + BitsPerLevel))
          F(SlotA);
      } else {
        F(SlotA);
      }
    }
  }
};

} // namespace enzyme_detail

template <typename T> class PersistentPtrSet {
  using Trie = enzyme_detail::PersistentPtrTrie;

  Trie::Node *Root = nullptr;
  size_t NumElements = 0;

  static uintptr_t toKey(const T *P) {
    uintptr_t Key = reinterpret_cast<uintptr_t>(P);
    assert(!Trie::isChild(Key) && "pointers must be aligned");
    return Key;
  }
  static T *fromKey(uintptr_t Key) { return reinterpret_cast<T *>(Key); }

public:
  PersistentPtrSet() = default;
  PersistentPtrSet(const PersistentPtrSet &Other)
      : Root(Other.Root), NumElements(Other.NumElements) {
    Trie::retain(Root);
  }
  PersistentPtrSet(PersistentPtrSet &&Other)
      : Root(Other.Root), NumElements(Other.NumElements) {
    Other.Root = nullptr;
    Other.NumElements = 0;
  }
  PersistentPtrSet &operator=(PersistentPtrSet Other) {
    std::swap(Root, Other.Root);
    std::swap(NumElements, Other.NumElements);
    return *this;
  }
  ~PersistentPtrSet() { Trie::release(Root); }

  size_t size() const { return NumElements; }
  bool empty() const { return NumElements == 0; }

  bool count(const T *P) const {
    uintptr_t Key = toKey(P);
    return Trie::contains(Root, Key, Trie::mix(Key));
  }

  /// Returns whether P was added, that is, whether it was missing.
  bool insert(T *P) {
    uintptr_t Key = toKey(P);
    uint64_t Hash = Trie::mix(Key);
    if (Trie::contains(Root, Key, Hash))
      return false;
    if (Root) {
      Root = Trie::insertAbsent(Root, Key, Hash, 0);
    } else {
      Root = Trie::allocate(1, Trie::sliceBit(Hash, 0));
      Root->Slots[0] = Key;
    }
    ++NumElements;
    return true;
  }

  /// Returns whether P was removed, that is, whether it was present.
  bool erase(const T *P) {
    uintptr_t Key = toKey(P);
    uint64_t Hash = Trie::mix(Key);
    if (!Trie::contains(Root, Key, Hash))
      return false;
    Root = Trie::erasePresent(Root, Key, Hash, 0);
    --NumElements;
    return true;
  }

  template <typename Fn> void forEach(Fn &&F) const {
    PersistentPtrSet Snapshot(*this);
    Trie::forEach(Snapshot.Root, [&](uintptr_t Key) { F(fromKey(Key)); });
  }

  /// Calls F for each element missing from Other. Works on snapshots of both
  /// sets, so F may change either of them. Its cost follows the size of the
  /// difference between the sets when they derive from one another.
  template <typename Fn>
  void forEachMissingFrom(const PersistentPtrSet &Other, Fn &&F) const {
    PersistentPtrSet A(*this), B(Other);
    Trie::forEachMissing(A.Root, B.Root, 0,
                         [&](uintptr_t Key) { F(fromKey(Key)); });
  }
};

#endif
