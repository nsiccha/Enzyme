//===- ActivityReEvaluation.h - Deferred activity dependencies ------------===//
//
// Part of the Enzyme Project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef ENZYME_ACTIVITY_RE_EVALUATION_H
#define ENZYME_ACTIVITY_RE_EVALUATION_H

#include <cstdint>
#include <utility>

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallPtrSet.h"

namespace enzyme_detail {

/// What to evaluate again once a key is shown to be inactive. A key can
/// already be known inactive when it gets its entry; such an entry runs the
/// next time a hypothesis that also knows the key is imported. So that an
/// import need not visit everything the hypothesis knows to find them, this
/// remembers the keys that may be in that state.
template <typename KeyT, typename ItemT> class ActivityReEvaluationMap {
  llvm::DenseMap<KeyT *, llvm::SmallPtrSet<ItemT *, 4>> Entries;
  llvm::SmallPtrSet<KeyT *, 4> KeysToRecheck;
  llvm::DenseMap<std::pair<KeyT *, ItemT *>, uint64_t> EvaluatedAt;

public:
  llvm::SmallPtrSet<ItemT *, 4> &operator[](KeyT *Key) {
    KeysToRecheck.insert(Key);
    return Entries[Key];
  }
  auto begin() { return Entries.begin(); }
  auto end() { return Entries.end(); }
  auto find(KeyT *Key) { return Entries.find(Key); }
  bool count(KeyT *Key) const { return Entries.count(Key); }
  /// Removes the entry of Key and returns what it held.
  llvm::SmallPtrSet<ItemT *, 4> take(typename decltype(Entries)::iterator It) {
    auto Items = std::move(It->second);
    Entries.erase(It);
    return Items;
  }
  /// Empties and returns the keys to check, which the caller keeps or gives
  /// back through keepForRecheck.
  llvm::SmallPtrSet<KeyT *, 4> takeKeysToRecheck() {
    auto Keys = std::move(KeysToRecheck);
    KeysToRecheck.clear();
    return Keys;
  }
  void keepForRecheck(KeyT *Key) { KeysToRecheck.insert(Key); }

  /// Record before invoking the analysis: importing a hypothesis can refill
  /// this very dependency and re-enter its consumer. For a fixed set of
  /// inactive facts each pair runs at most once, including across take/refill.
  /// New facts permit another attempt; keep a suppressed dependency pending
  /// for that later import. Neither permanently blacklisting the pair nor
  /// discarding it on suppression would preserve that opportunity. Versions
  /// must only increase when a new fact is proved.
  bool markEvaluated(KeyT *Key, ItemT *Item, uint64_t FactsVersion) {
    auto Result = EvaluatedAt.insert({{Key, Item}, FactsVersion});
    if (Result.second)
      return true;
    if (Result.first->second == FactsVersion) {
      (*this)[Key].insert(Item);
      return false;
    }
    Result.first->second = FactsVersion;
    return true;
  }
};

} // namespace enzyme_detail

#endif
