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
#endif

namespace confighttp {
  void send_response(resp_https_t response,const nlohmann::json &value);
  void bad_request(resp_https_t response,req_https_t request,const std::string &message);
  bool check_content_type(resp_https_t response,req_https_t request,const std::string_view &type);

  namespace {
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
      if (platf::is_running_as_system()) token=platf::retrieve_users_token(false);
      else if (!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY|TOKEN_DUPLICATE|TOKEN_IMPERSONATE,&token)) return result;
      if (!token) return result;
      result.token=std::shared_ptr<void>(token,[](void *v) {CloseHandle(static_cast<HANDLE>(v));});
      DWORD size=0;GetTokenInformation(token,TokenUser,nullptr,0,&size);std::vector<unsigned char> storage(size);
      if (!size || !GetTokenInformation(token,TokenUser,storage.data(),size,&size)) return moonshine::user_context {};
      LPWSTR sid=nullptr;if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER *>(storage.data())->User.Sid,&sid)) return moonshine::user_context {};
      for (const wchar_t *p=sid;*p;++p) result.sid.push_back(static_cast<char>(*p));LocalFree(sid);
      if (moonshine::service_preview() && result.sid!=moonshine::service_owner_sid()) return moonshine::user_context {};
      PWSTR local=nullptr;if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,token,&local)) || !local) return moonshine::user_context {};
      result.local_data=result.trial_id.empty() ? std::filesystem::path(local)/L"OPi5/VibeShine-Xbox" : std::filesystem::path(local)/L"OPi5/Moonshine-Trial"/std::filesystem::path(result.trial_id)/L"Sync";CoTaskMemFree(local);return result;
    };
    services.launch=[](const std::string &command,const std::wstring &directory,STARTUPINFOEXW &startup,PROCESS_INFORMATION &process,std::string &error) {
      std::error_code ec;
      const bool success=platf::is_running_as_system()
        ? platf::launch_process_with_impersonation(false,command,directory,CREATE_NO_WINDOW,startup,process,ec)
        : platf::launch_process_without_impersonation(command,directory,CREATE_NO_WINDOW,startup,process,ec);
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
