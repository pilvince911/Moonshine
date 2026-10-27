// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <filesystem>
#include <functional>
#include <memory>
#include <string>
#include <nlohmann/json.hpp>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <windows.h>
#endif

namespace moonshine {
  using json = nlohmann::json;
#ifdef _WIN32
  struct user_context {
    std::shared_ptr<void> token;
    std::string sid;
    std::filesystem::path local_data;
    std::string trial_id;
  };
  struct host_services {
    std::filesystem::path package;
    std::function<user_context()> user;
    std::function<bool(const std::string &, const std::wstring &, STARTUPINFOEXW &, PROCESS_INFORMATION &, std::string &)> launch;
    std::function<std::string(const std::string &)> issue_token;
    std::function<void(const std::string &)> revoke_token;
    std::function<std::pair<std::string,std::string>()> endpoint;
    std::function<bool()> idle;
  };
  void configure(host_services services);
  std::string trial_id();
  void validate_startup();
#endif
  void start();
  void stop();
  json status();
  json submit(const json &request);
  json job(const std::string &id);
  json confirm(const std::string &id, const json &request);
  json cancel(const std::string &id);
}
