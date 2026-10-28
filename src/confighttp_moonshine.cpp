// SPDX-License-Identifier: GPL-3.0-only
#include "moonshine/bridge.h"
#include "moonshine/policy.h"
#include "confighttp.h"
#include "config.h"
#include "file_handler.h"
#include "globals.h"
#include "network.h"
#include "process.h"
#include "rtsp.h"
#include "webrtc_stream.h"
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <sstream>
#include <vector>
#include <iomanip>
#ifdef _WIN32
#include "platform/windows/misc.h"
#include <sddl.h>
#include <shlobj.h>
#include <userenv.h>
#endif

namespace confighttp {
  void send_response(resp_https_t response,const nlohmann::json &value);
  void bad_request(resp_https_t response,req_https_t request,const std::string &message);
  bool check_content_type(resp_https_t response,req_https_t request,const std::string_view &type);

  namespace {
#ifdef _WIN32
    std::shared_ptr<void> normal_console_token() {
      const auto own=[](HANDLE value) { return std::shared_ptr<void>(value,[](void *p) {if (p) CloseHandle(static_cast<HANDLE>(p));}); };
      auto token=own(platf::retrieve_users_token(false));if (!token) return {};
      DWORD bytes=0;TOKEN_ELEVATION_TYPE type;
      if (!GetTokenInformation(token.get(),TokenElevationType,&type,sizeof(type),&bytes)) return {};
      if (type==TokenElevationTypeFull) {
        TOKEN_LINKED_TOKEN linked {};
        if (!GetTokenInformation(token.get(),TokenLinkedToken,&linked,sizeof(linked),&bytes)) return {};
        token=own(linked.LinkedToken);
      }
      TOKEN_ELEVATION elevation {};
      if (!GetTokenInformation(token.get(),TokenElevation,&elevation,sizeof(elevation),&bytes)) return {};
      if (elevation.TokenIsElevated) {
        // With UAC disabled there is no linked limited token. Build a normal
        // user token without administrator groups or administrative privileges.
        DWORD admin[SECURITY_MAX_SID_SIZE/sizeof(DWORD)] {};DWORD size=sizeof(admin);
        if (!CreateWellKnownSid(WinBuiltinAdministratorsSid,nullptr,admin,&size)) return {};
        SID_AND_ATTRIBUTES disabled {admin,0};HANDLE limited=nullptr;
        if (!CreateRestrictedToken(token.get(),DISABLE_MAX_PRIVILEGE|LUA_TOKEN,1,&disabled,0,nullptr,0,nullptr,&limited)) return {};
        token=own(limited);
        PSID medium=nullptr;if (!ConvertStringSidToSidW(L"S-1-16-8192",&medium)) return {};
        TOKEN_MANDATORY_LABEL label {{medium,SE_GROUP_INTEGRITY}};
        const bool lowered=SetTokenInformation(token.get(),TokenIntegrityLevel,&label,sizeof(label)+GetLengthSid(medium))!=FALSE;
        LocalFree(medium);if (!lowered) return {};
      }
      // Refuse any token that still carries effective administrator membership.
      HANDLE impersonation=nullptr;
      if (!DuplicateToken(token.get(),SecurityIdentification,&impersonation)) return {};
      const auto duplicate=own(impersonation);
      DWORD admin[SECURITY_MAX_SID_SIZE/sizeof(DWORD)] {};DWORD size=sizeof(admin);BOOL member=TRUE;
      if (!CreateWellKnownSid(WinBuiltinAdministratorsSid,nullptr,admin,&size) || !CheckTokenMembership(duplicate.get(),admin,&member) || member) return {};
      return token;
    }
#endif
    nlohmann::json body(req_https_t request) {
      if (request->content.size()>65536) throw std::runtime_error("Requête Moonshine trop volumineuse.");
      std::stringstream text;text<<request->content.rdbuf();
      const auto result=nlohmann::json::parse(text.str());if (!result.is_object()) throw std::runtime_error("Requête Moonshine invalide.");return result;
    }
  }
  void initializeMoonshine() {
#ifdef _WIN32
    // Remove only the exact namespace used for abandoned temporary job tokens.
    for (const auto &item:api_token_manager.get_api_tokens_list()) {
      const auto name=item.value("username","");constexpr std::string_view prefix="moonshine-job:";
      if (name.starts_with(prefix) && moonshine::policy::id(std::string_view(name).substr(prefix.size()))) api_token_manager.revoke_api_token_by_hash(item.value("hash",""));
    }
    moonshine::host_services services;
    std::wstring executable(32768,L'\0');const auto length=GetModuleFileNameW(nullptr,executable.data(),static_cast<DWORD>(executable.size()));
    if (!length || length>=executable.size()) throw std::runtime_error("Chemin Moonshine indisponible.");executable.resize(length);
    services.package=std::filesystem::path(executable).parent_path()/L"tools/moonshine";
    services.user=[]() {
      moonshine::user_context result;
      result.trial_id=moonshine::trial_id();
      if (!result.trial_id.empty() && platf::is_running_as_system() && !moonshine::service_preview()) throw std::runtime_error("L’essai Moonshine doit utiliser une session Windows normale.");
      HANDLE token=nullptr;
      if (platf::is_running_as_system()) {result.token=normal_console_token();token=static_cast<HANDLE>(result.token.get());}
      else if (OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY|TOKEN_DUPLICATE|TOKEN_IMPERSONATE,&token)) result.token=std::shared_ptr<void>(token,[](void *v) {CloseHandle(static_cast<HANDLE>(v));});
      if (!token) return result;
      DWORD size=0;GetTokenInformation(token,TokenUser,nullptr,0,&size);std::vector<unsigned char> storage(size);
      if (!size || !GetTokenInformation(token,TokenUser,storage.data(),size,&size)) return moonshine::user_context {};
      LPWSTR sid=nullptr;if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER *>(storage.data())->User.Sid,&sid)) return moonshine::user_context {};
      for (const wchar_t *p=sid;*p;++p) result.sid.push_back(static_cast<char>(*p));LocalFree(sid);
      if (moonshine::service_preview() && result.sid!=moonshine::service_owner_sid()) return moonshine::user_context {};
      PWSTR local=nullptr;if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,token,&local)) || !local) return moonshine::user_context {};
      result.local_data=result.trial_id.empty() ? std::filesystem::path(local)/L"OPi5/VibeShine-Xbox" : std::filesystem::path(local)/L"OPi5/Moonshine-Trial"/std::filesystem::path(result.trial_id)/L"Sync";CoTaskMemFree(local);return result;
    };
    services.launch=[user_context=services.user](const std::string &command,const std::wstring &directory,STARTUPINFOEXW &startup,PROCESS_INFORMATION &process,std::string &error) {
      std::error_code ec;
      if (platf::is_running_as_system()) {
        // The worker is an explicit packaged executable, not a shell/URL launch.
        // Keep the service's caller privileges while assigning the normal user's
        // primary token; do not impersonate around CreateProcessAsUserW.
        const auto user=user_context();
        if (!user.token || user.sid.empty()) { error="Session Windows sélectionnée indisponible.";return false; }
        void *environment=nullptr;
        if (!CreateEnvironmentBlock(&environment,static_cast<HANDLE>(user.token.get()),FALSE)) {error="CreateEnvironmentBlock Windows "+std::to_string(GetLastError());return false;}
        const int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,command.data(),static_cast<int>(command.size()),nullptr,0);
        if (!count) {const auto code=GetLastError();DestroyEnvironmentBlock(environment);error="Commande interne Windows "+std::to_string(code);return false;}
        std::vector<wchar_t> text(static_cast<std::size_t>(count)+1,L'\0');MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,command.data(),static_cast<int>(command.size()),text.data(),count);
        startup.StartupInfo.lpDesktop=const_cast<wchar_t *>(L"winsta0\\default");
        const DWORD flags=CREATE_NO_WINDOW|CREATE_UNICODE_ENVIRONMENT|(startup.lpAttributeList?EXTENDED_STARTUPINFO_PRESENT:0);
        const bool success=CreateProcessAsUserW(static_cast<HANDLE>(user.token.get()),nullptr,text.data(),nullptr,nullptr,FALSE,flags,environment,directory.c_str(),reinterpret_cast<LPSTARTUPINFOW>(&startup),&process)!=FALSE;
        const auto code=success?ERROR_SUCCESS:GetLastError();DestroyEnvironmentBlock(environment);
        if (!success) error="CreateProcessAsUserW Windows "+std::to_string(code);return success;
      }
      const bool success=platf::launch_process_without_impersonation(command,directory,CREATE_NO_WINDOW,startup,process,ec);
      if (!success) error="Windows "+std::to_string(ec.value());return success;
    };
    services.issue_token=[](const std::string &owner) {
      const nlohmann::json scopes=nlohmann::json::array({
        {{"path","/api/apps"},{"methods",{"GET","POST"}}},
        {{"path","/api/apps/706c6f73-7862-[A-Fa-f0-9-]+"},{"methods",{"DELETE"}}},
        {{"path","/api/session/status"},{"methods",{"GET"}}}});
      const auto token=api_token_manager.create_api_token(scopes,owner);return token.value_or("");
    };
    services.revoke_token=[](const std::string &owner) {
      for (const auto &item:api_token_manager.get_api_tokens_list()) if (item.value("username","")==owner) api_token_manager.revoke_api_token_by_hash(item.value("hash",""));
    };
    services.endpoint=[]() {
      if (!moonshine::trial_id().empty() && net::map_port(PORT_HTTPS)!=48990) throw std::runtime_error("Cet essai utilise le port HTTPS 48990.");
      const auto pem=file_handler::read_file(config::nvhttp.cert.c_str());
      const std::unique_ptr<BIO,decltype(&BIO_free)> input(BIO_new_mem_buf(pem.data(),static_cast<int>(pem.size())),BIO_free);
      const std::unique_ptr<X509,decltype(&X509_free)> cert(input?PEM_read_bio_X509(input.get(),nullptr,nullptr,nullptr):nullptr,X509_free);
      unsigned char digest[EVP_MAX_MD_SIZE];unsigned int count=0;
      if (!cert || X509_digest(cert.get(),EVP_sha256(),digest,&count)!=1 || count!=32) throw std::runtime_error("Certificat HTTPS local indisponible.");
      std::ostringstream pin;pin<<std::hex<<std::setfill('0');for (unsigned int i=0;i<count;++i) pin<<std::setw(2)<<static_cast<unsigned int>(digest[i]);
      return std::make_pair("https://127.0.0.1:"+std::to_string(net::map_port(PORT_HTTPS)),pin.str());
    };
    services.idle=[]() {return rtsp_stream::session_count_no_cleanup()==0 && webrtc_stream::active_session_count()==0 && proc::proc.current_app_id()<=0;};
    services.request_shutdown=[]() {mail::man->event<bool>(mail::shutdown)->raise(true);};
    moonshine::configure(std::move(services));moonshine::start();
#endif
  }
  void getMoonshineStatus(resp_https_t response,req_https_t request) {
    if (!authenticate(response,request)) return;
    try {send_response(response,moonshine::status());} catch (const std::exception &e) {bad_request(response,request,e.what());}
  }
  void postMoonshineJob(resp_https_t response,req_https_t request) {
    if (!check_content_type(response,request,"application/json") || !authenticate(response,request)) return;
    try {send_response(response,moonshine::submit(body(request)));} catch (const std::exception &e) {bad_request(response,request,e.what());}
  }
  void getMoonshineJob(resp_https_t response,req_https_t request) {
    if (!authenticate(response,request)) return;
    try {send_response(response,moonshine::job(request->path_match[1].str()));} catch (const std::exception &e) {bad_request(response,request,e.what());}
  }
  void postMoonshineConfirm(resp_https_t response,req_https_t request) {
    if (!check_content_type(response,request,"application/json") || !authenticate(response,request)) return;
    try {send_response(response,moonshine::confirm(request->path_match[1].str(),body(request)));} catch (const std::exception &e) {bad_request(response,request,e.what());}
  }
  void postMoonshineCancel(resp_https_t response,req_https_t request) {
    if (!check_content_type(response,request,"application/json") || !authenticate(response,request)) return;
    try {send_response(response,moonshine::cancel(request->path_match[1].str()));} catch (const std::exception &e) {bad_request(response,request,e.what());}
  }
}
