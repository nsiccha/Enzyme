// RUN: %activityReEvaluationTest
//
// Part of the Enzyme Project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#include "ActivityReEvaluation.h"
#include "PersistentPtrSet.h"

#include <cstdio>
#include <cstdlib>

#define CHECK(Condition)                                                       \
  do {                                                                         \
    if (!(Condition)) {                                                        \
      std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #Condition);     \
      std::exit(1);                                                            \
    }                                                                          \
  } while (false)

using enzyme_detail::ActivityReEvaluationMap;

// An old hypothesis can import an active result and register a dependency on
// an instruction which the caller already knows is inactive. Re-evaluating it
// imports another old hypothesis, closing a cycle without learning anything.
// Model only those dependency operations, without an LLVM module or analyzer.
struct Cycle {
  int Keys[2] = {};
  int Values[2] = {};
  int NewFact = 0;
  bool Active[2] = {true, true};
  unsigned Attempts[2] = {};
  uint64_t Version = 0;
  PersistentPtrSet<int> Inactive;
  ActivityReEvaluationMap<int, int> Dependencies;

  void learn(int *Fact) {
    if (Inactive.insert(Fact))
      ++Version;
  }

  void run(unsigned Index) {
    auto Found = Dependencies.find(&Keys[Index]);
    if (Found == Dependencies.end())
      return;
    auto Items = Dependencies.take(Found);
    for (auto Item : Items) {
      CHECK(Item == &Values[Index]);
      if (!Active[Index] ||
          !Dependencies.markEvaluated(&Keys[Index], Item, Version))
        continue;
      Active[Index] = false;
      // Fail in bounded time if duplicate suppression is removed.
      CHECK(++Attempts[Index] <= 4);
      if (Inactive.count(&NewFact)) {
        learn(Item);
        continue;
      }
      Active[Index] = true;
      unsigned Other = 1 - Index;
      Dependencies[&Keys[Other]].insert(&Values[Other]);
      learn(&Keys[Other]); // Already known; this must not count as progress.
      run(Other);
    }
  }
};

static void cyclicImportsAndNewFacts() {
  Cycle C;
  C.learn(&C.Keys[0]);
  C.learn(&C.Keys[1]);
  C.Dependencies[&C.Keys[0]].insert(&C.Values[0]);
  C.run(0);
  CHECK(C.Version == 2);
  CHECK(C.Attempts[0] == 1 && C.Attempts[1] == 1);
  CHECK(C.Active[0] && C.Active[1]);

  // A later import of exactly the same dependencies still makes no progress.
  C.Dependencies[&C.Keys[0]].insert(&C.Values[0]);
  C.Dependencies[&C.Keys[1]].insert(&C.Values[1]);
  C.run(0);
  C.run(1);
  CHECK(C.Attempts[0] == 1 && C.Attempts[1] == 1);
  CHECK(C.Dependencies.count(&C.Keys[0]));
  CHECK(C.Dependencies.count(&C.Keys[1]));

  // A real new fact changes the outcome. A permanent consumed-pair set would
  // suppress these attempts and leave both values incorrectly unresolved. No
  // dependency is registered again: the suppressed pairs must remain pending.
  C.learn(&C.NewFact);
  for (auto Key : C.Dependencies.takeKeysToRecheck())
    C.run(Key == &C.Keys[0] ? 0 : 1);
  CHECK(C.Attempts[0] == 2 && C.Attempts[1] == 2);
  CHECK(!C.Active[0] && !C.Active[1]);
  CHECK(C.Inactive.count(&C.Values[0]));
  CHECK(C.Inactive.count(&C.Values[1]));
}

static void distinctDependencies() {
  int Keys[2] = {}, Items[2] = {};
  ActivityReEvaluationMap<int, int> Map;
  CHECK(Map.markEvaluated(&Keys[0], &Items[0], 0));
  CHECK(!Map.markEvaluated(&Keys[0], &Items[0], 0));
  CHECK(Map.markEvaluated(&Keys[0], &Items[1], 0));
  CHECK(Map.markEvaluated(&Keys[1], &Items[0], 0));
  CHECK(Map.markEvaluated(&Keys[0], &Items[0], 1));
  CHECK(!Map.markEvaluated(&Keys[0], &Items[0], 1));

  // Hypotheses own their histories; consuming a pair in one analyzer cannot
  // prevent another analyzer (with different assumptions) from processing it.
  ActivityReEvaluationMap<int, int> Hypothesis;
  CHECK(Hypothesis.markEvaluated(&Keys[0], &Items[0], 1));
}

static void deferredKeysAndRefill() {
  int Keys[2] = {}, Items[2] = {};
  ActivityReEvaluationMap<int, int> Map;
  Map[&Keys[0]].insert(&Items[0]);
  Map[&Keys[0]].insert(&Items[0]);
  Map[&Keys[1]].insert(&Items[1]);
  auto KeysToCheck = Map.takeKeysToRecheck();
  CHECK(KeysToCheck.size() == 2);
  CHECK(Map.takeKeysToRecheck().empty());
  // The imported hypothesis does not yet know key 1; keep it for another one.
  Map.keepForRecheck(&Keys[1]);
  auto Taken = Map.take(Map.find(&Keys[0]));
  CHECK(Taken.size() == 1 && Taken.count(&Items[0]));
  CHECK(!Map.count(&Keys[0]));
  CHECK(Map.count(&Keys[1]));
  CHECK(Map.markEvaluated(&Keys[0], &Items[0], 0));
  Map[&Keys[0]].insert(&Items[0]);
  CHECK(!Map.markEvaluated(&Keys[0], &Items[0], 0));
  KeysToCheck = Map.takeKeysToRecheck();
  CHECK(KeysToCheck.count(&Keys[0]) && KeysToCheck.count(&Keys[1]));
}

int main() {
  cyclicImportsAndNewFacts();
  distinctDependencies();
  deferredKeysAndRefill();
  std::puts("activity dependency regression passed");
}
