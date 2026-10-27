// SPDX-License-Identifier: GPL-3.0-only
#include "../../src/moonshine/policy.h"
#include <cassert>
#include <iostream>

int main() {
  using namespace moonshine::policy;
  for (auto command : actions) assert(action(command, true));
  assert(!action("auto") && action("auto", true));
  assert(!action("powershell.exe") && !action("../sync") && !scope("arbitrary"));
  assert(scope("all") && scope("ea") && scope("pilot") && scope("ea-pilot"));
  assert(game_id("706c6f73-7862-8830-81ec-2118ff82baaa"));
  assert(!game_id("00000000-0000-4000-8000-000000000001"));
  assert(!game_id("706c6f73-7862-8830-81ec-2118ff82baa/"));
  assert(mode("game-provided") && mode("off") && mode("unmanaged") && !mode("force-4x"));
  const std::string nonce(32,'a'), stale(32,'b');
  assert(confirmation(nonce, nonce, true, "REINITIALISER", "REINITIALISER", true));
  assert(!confirmation(nonce, stale, false, "APPLIQUER", "", true));
  assert(!confirmation(nonce, nonce, true, "REINITIALISER", "reinitialiser", true));
  assert(confirmation(nonce, nonce, true, "REINITIALISER", "", false));
  assert(!confirmation("", "", false, "APPLIQUER", "", true));
  const auto now=std::chrono::steady_clock::now();
  assert(automatic_due(true,false,true,true,now,now));
  assert(!automatic_due(true,true,true,true,now,now));
  assert(!automatic_due(true,false,true,false,now,now));
  assert(!automatic_due(true,false,false,true,now,now));
  assert(!automatic_due(false,false,true,true,now,now));
  assert(!automatic_due(true,false,true,true,now,now+std::chrono::minutes(1)));
  assert(terminal("completed") && terminal("failed") && terminal("cancelled") && !terminal("awaiting_confirmation"));
  assert(bounded(std::string(4000,'x')).size()==1800);
  assert(bounded(std::string(1799,'x')+"\xc3\xa9"+"end").size()==1799);
  std::cout << "Moonshine provider policy: passed\n";
}
