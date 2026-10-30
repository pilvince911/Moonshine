// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <string>
#include <string_view>

namespace moonshine::policy {
  inline constexpr std::array<std::string_view,11> actions {"preview", "sync", "reset", "restore", "undo", "profile", "creation_profile", "export", "enable_auto", "disable_auto", "auto"};
  inline constexpr std::array<std::string_view,4> scopes {"all", "ea", "pilot", "ea-pilot"};
  inline bool action(std::string_view value, bool internal = false) {
    return std::find(actions.begin(), actions.end(), value) != actions.end() && (internal || value != "auto");
  }
  inline bool scope(std::string_view value) { return std::find(scopes.begin(), scopes.end(), value) != scopes.end(); }
  inline bool id(std::string_view value) {
    return value.size() == 32 && std::all_of(value.begin(), value.end(), [](unsigned char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); });
  }
  inline bool game_id(std::string_view value) {
    if (value.size() != 36 || !value.starts_with("706c6f73-7862-8") || value[19] != '8') return false;
    for (std::size_t i = 0; i < value.size(); ++i) {
      if (i == 8 || i == 13 || i == 18 || i == 23) { if (value[i] != '-') return false; }
      else if (!((value[i] >= '0' && value[i] <= '9') || (value[i] >= 'a' && value[i] <= 'f'))) return false;
    }
    return true;
  }
  inline bool mode(std::string_view value) { return value == "game-provided" || value == "off" || value == "unmanaged"; }
  inline bool terminal(std::string_view state) { return state == "completed" || state == "failed" || state == "cancelled"; }
  inline bool confirmation(std::string_view nonce, std::string_view reply_nonce, bool typed, std::string_view expected, std::string_view text, bool accept) {
    return id(nonce) && nonce == reply_nonce && (!accept || !typed || text == expected);
  }
  inline bool automatic_due(bool enabled, bool busy, bool user_active, bool idle, std::chrono::steady_clock::time_point now, std::chrono::steady_clock::time_point next) {
    return enabled && !busy && user_active && idle && now >= next;
  }
  inline std::string bounded(std::string value, std::size_t limit = 1800) {
    if (value.size() > limit) {
      while (limit && (static_cast<unsigned char>(value[limit]) & 0xc0) == 0x80) --limit;
      value.resize(limit);
    }
    return value;
  }
}
