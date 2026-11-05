// SPDX-License-Identifier: GPL-3.0-only
#include "../../src/moonshine/bridge.h"
#include "../../src/moonshine/policy.h"
#include <sddl.h>
#include <atomic>
#include <cassert>
#include <chrono>
#include <filesystem>
#include <iostream>
#include <thread>

namespace {
  std::string sid() {
    HANDLE token=nullptr;if (!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token)) throw std::runtime_error("token");
    DWORD size=0;GetTokenInformation(token,TokenUser,nullptr,0,&size);std::vector<unsigned char> bytes(size);
    if (!GetTokenInformation(token,TokenUser,bytes.data(),size,&size)) throw std::runtime_error("user");
    LPWSTR text=nullptr;if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER *>(bytes.data())->User.Sid,&text)) throw std::runtime_error("sid");
    std::string value;for (auto p=text;*p;++p)value.push_back(static_cast<char>(*p));LocalFree(text);CloseHandle(token);return value;
  }
  moonshine::json await(const std::string &id,const std::string &state) {
    for (int n=0;n<600;++n) {auto result=moonshine::job(id);if (result["state"]==state)return result;if (result["state"]=="failed") throw std::runtime_error(result.dump());std::this_thread::sleep_for(std::chrono::milliseconds(50));}
    throw std::runtime_error("fixture timeout");
  }
}
int main(int argc,char **argv) {
  assert(argc==2);const auto directory=std::filesystem::absolute(argv[1]);
  std::atomic<int> issued {0},revoked {0},shutdown {0};std::atomic<bool> early_exit {false};const std::string secret="synthetic-private-token-123456789";
  moonshine::host_services host;host.package=directory;
  host.user=[directory]() {HANDLE token=nullptr;if (!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY|TOKEN_DUPLICATE|TOKEN_IMPERSONATE,&token)) throw std::runtime_error("token");return moonshine::user_context{std::shared_ptr<void>(token,[](void *p){CloseHandle(static_cast<HANDLE>(p));}),sid(),directory,std::string(32,'a')};};
  host.endpoint=[](){return std::make_pair("https://127.0.0.1:47990",std::string(64,'a'));};
  host.issue_token=[&](const std::string &){issued++;return secret;};host.revoke_token=[&](const std::string &){revoked++;};host.idle=[](){return true;};
  host.launch=[&early_exit](const std::string &command,const std::wstring &directory,STARTUPINFOEXW &startup,PROCESS_INFORMATION &info,std::string &error) {
    const int length=MultiByteToWideChar(CP_UTF8,0,command.data(),static_cast<int>(command.size()),nullptr,0);std::wstring wide(length,L'\0');MultiByteToWideChar(CP_UTF8,0,command.data(),static_cast<int>(command.size()),wide.data(),length);wide.push_back(L'\0');
    if (early_exit) {wchar_t system[MAX_PATH];assert(GetSystemDirectoryW(system,MAX_PATH));wide=L"\""+(std::filesystem::path(system)/L"cmd.exe").wstring()+L"\" /d /c exit 23";wide.push_back(L'\0');}
    assert((startup.StartupInfo.dwFlags & STARTF_USESTDHANDLES)==0);
    const bool success=CreateProcessW(nullptr,wide.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,directory.c_str(),reinterpret_cast<STARTUPINFOW *>(&startup),&info)!=FALSE;
    if (!success)error=std::to_string(GetLastError());return success;
  };
  host.request_shutdown=[&]() {shutdown++;};
  moonshine::configure(std::move(host));moonshine::start();
  try {
    auto created=moonshine::submit({{"action","preview"},{"scope","all"}});const auto id=created["job_id"].get<std::string>();
    auto prompt=await(id,"awaiting_confirmation");assert(prompt.dump().find(secret)==std::string::npos);
    bool rejected=false;try {moonshine::submit({{"action","sync"},{"scope","all"}});}catch(...){rejected=true;}assert(rejected);
    rejected=false;try {moonshine::confirm(id,{{"nonce",std::string(32,'0')},{"accept",true}});}catch(...){rejected=true;}assert(rejected);
    moonshine::confirm(id,{{"nonce",prompt["prompt"]["nonce"]},{"accept",true}});auto result=await(id,"completed");assert(result.dump().find(secret)==std::string::npos);
    // The terminal state follows child exit; the next job can start immediately.
    created=moonshine::submit({{"action","preview"},{"scope","all"}});const auto second=created["job_id"].get<std::string>();await(second,"awaiting_confirmation");moonshine::cancel(second);await(second,"cancelled");
    rejected=false;try {moonshine::confirm(id,{{"nonce",prompt["prompt"]["nonce"]},{"accept",true}});}catch(...){rejected=true;}assert(rejected);
    rejected=false;try {moonshine::submit({{"action","auto"},{"scope","all"}});}catch(...){rejected=true;}assert(rejected);
    // A real process that dies before opening the pipe must expose its native
    // exit status and still release its temporary authorization.
    early_exit=true;created=moonshine::submit({{"action","preview"},{"scope","all"}});
    result=await(created["job_id"].get<std::string>(),"failed");
    assert(result["message"].get<std::string>().find("0x00000017")!=std::string::npos && result.dump().find(secret)==std::string::npos);
    assert(issued==3 && revoked==3);early_exit=false;
    assert(moonshine::status()["isolated"]==true);
    const auto event=OpenEventW(EVENT_MODIFY_STATE,FALSE,L"Global\\Moonshine.Trial.Stop.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    assert(event);assert(SetEvent(event));CloseHandle(event);
    for(int n=0;n<100 && shutdown==0;++n)std::this_thread::sleep_for(std::chrono::milliseconds(50));
    assert(shutdown==1);
    moonshine::stop();assert(issued==3 && revoked==3);
    std::cout<<"Moonshine Windows process/pipe/prompt/cancellation/token lifecycle: passed\n";
  } catch (...) {moonshine::stop();throw;}
}
