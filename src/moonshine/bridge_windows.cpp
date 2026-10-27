// SPDX-License-Identifier: GPL-3.0-only
#include "bridge.h"
#include "policy.h"
#include <stdexcept>
#ifdef _WIN32
#include <sddl.h>
#include <objbase.h>
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <fstream>
#include <mutex>
#include <stdexcept>
#include <cstdio>
#include <iterator>
#include <thread>
#include <vector>

namespace moonshine {
  namespace {
    struct handle {
      HANDLE value = nullptr;
      handle() = default;
      explicit handle(HANDLE v): value(v) {}
      ~handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
      handle(const handle &) = delete;
      handle &operator=(const handle &) = delete;
      HANDLE release() { const auto v=value; value=nullptr; return v; }
    };
    std::string random_id() {
      GUID value; if (FAILED(CoCreateGuid(&value))) throw std::runtime_error("Identifiant interne indisponible.");
      char text[33]; snprintf(text,sizeof(text),"%08lx%04x%04x%02x%02x%02x%02x%02x%02x%02x%02x",static_cast<unsigned long>(value.Data1),value.Data2,value.Data3,
        value.Data4[0],value.Data4[1],value.Data4[2],value.Data4[3],value.Data4[4],value.Data4[5],value.Data4[6],value.Data4[7]);
      return text;
    }
    std::wstring wide(const std::string &value) {
      if (value.empty()) return {};
      const int length=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value.data(),static_cast<int>(value.size()),nullptr,0);
      if (!length) throw std::runtime_error("Texte interne invalide.");
      std::wstring result(length,L'\0'); MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value.data(),static_cast<int>(value.size()),result.data(),length); return result;
    }
    std::string utf8(const std::wstring &value) {
      const int length=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.data(),static_cast<int>(value.size()),nullptr,0,nullptr,nullptr);
      if (!length) return {};
      std::string result(length,'\0'); WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value.data(),static_cast<int>(value.size()),result.data(),length,nullptr,nullptr); return result;
    }
    json read_user_json(const user_context &user, const std::filesystem::path &name, std::size_t limit) {
      if (!user.token || !ImpersonateLoggedOnUser(static_cast<HANDLE>(user.token.get()))) return {};
      struct revert { ~revert() { RevertToSelf(); } } guard;
      try {
        const auto path=user.local_data/name;
        if (!std::filesystem::is_regular_file(path) || std::filesystem::file_size(path)>limit) return {};
        std::ifstream input(path,std::ios::binary); std::string data(limit+1,'\0');input.read(data.data(),static_cast<std::streamsize>(data.size()));const auto count=input.gcount();
        if (count<0 || static_cast<std::size_t>(count)>limit) return {};
        data.resize(static_cast<std::size_t>(count));return json::parse(data);
      } catch (...) { return {}; }
    }
    bool auto_enabled(const user_context &user) {
      const auto data=read_user_json(user,"moonshine-auto.json",16384);
      return data.is_object() && data.value("schema","")=="moonshine-auto/1" && data.contains("enabled") && data["enabled"].is_boolean() && data["enabled"].get<bool>();
    }
    struct record {
      std::string id, owner, action, outcome, state="queued", message="Préparation…";
      int percent=-1;
      json parameters, snapshot, prompt;
      std::deque<std::string> logs;
      bool cancel_requested=false, received_terminal=false, exited=false;
      handle cancellation, input;
      std::thread thread;
      mutable std::mutex mutex;
      ~record() { if (thread.joinable()) { if (thread.get_id()==std::this_thread::get_id()) thread.detach(); else thread.join(); } }
    };
    host_services host;
    std::mutex manager_mutex;
    std::deque<std::shared_ptr<record>> records;
    std::shared_ptr<record> active;
    std::thread ticker;
    std::atomic<bool> stopping {false};
    std::condition_variable wake;
    std::mutex wake_mutex;
    bool configured=false;

    json public_record(const std::shared_ptr<record> &value) {
      std::lock_guard guard(value->mutex);
      return {{"status",true},{"job_id",value->id},{"action",value->action},{"state",value->state},
        {"message",value->message},{"percent",value->percent},{"snapshot",value->snapshot},{"prompt",value->prompt},{"logs",value->logs}};
    }
    bool busy_locked() {
      if (!active) return false;
      std::lock_guard guard(active->mutex); return !active->exited;
    }
    std::shared_ptr<record> find_locked(const std::string &id, const std::string &sid) {
      if (!policy::id(id)) throw std::runtime_error("Identifiant d’opération invalide.");
      const auto it=std::find_if(records.begin(),records.end(),[&](const auto &r) { return r->id==id && r->owner==sid; });
      if (it==records.end()) throw std::runtime_error("Opération indisponible dans cette session Windows.");
      return *it;
    }
    void write_pipe(HANDLE pipe, std::string text) {
      text+='\n'; std::size_t offset=0;
      while (offset<text.size()) { DWORD count=0;
        if (!WriteFile(pipe,text.data()+offset,static_cast<DWORD>(std::min<std::size_t>(text.size()-offset,65536)),&count,nullptr) || count==0) throw std::runtime_error("Communication interne interrompue.");
        offset+=count;
      }
      SecureZeroMemory(text.data(),text.size());
    }
    void apply_frame(const std::shared_ptr<record> &value, const std::string &line) {
      const auto frame=json::parse(line); const std::string type=frame.value("type","");
      if (!frame.contains("data") || !frame["data"].is_object()) throw std::runtime_error("Réponse interne invalide.");
      const auto &data=frame["data"];
      std::lock_guard guard(value->mutex);
      if (value->received_terminal) return;
      if (type=="snapshot") {
        if (data.value("schema","")!="moonshine-snapshot/1" || !data.contains("games") || !data["games"].is_array()) throw std::runtime_error("Instantané interne invalide.");
        value->snapshot=data;
      } else if (type=="prompt") {
        const std::string expected=data.value("expected","");
        if (expected!="APPLIQUER" && expected!="REINITIALISER" && expected!="RESTAURER" && expected!="ANNULER" && expected!="ACTIVER") throw std::runtime_error("Confirmation interne non reconnue.");
        if (value->action=="auto" || value->cancel_requested) { write_pipe(value->input.value,"{\"answer\":\"\"}"); return; }
        value->prompt=data;value->prompt["nonce"]=random_id();value->state="awaiting_confirmation";
        value->message="Examinez le plan et confirmez les changements.";
      } else if (type=="progress" || type=="log") {
        value->message=policy::bounded(data.value("message",""));
        if (type=="progress") value->percent=std::clamp(data.value("percent",-1),-1,100);
        else { value->logs.push_back(value->message);while (value->logs.size()>120) value->logs.pop_front(); }
      } else if (type=="complete" || type=="error" || type=="cancelled") {
        value->outcome=type=="complete"?"completed":type=="cancelled"?"cancelled":"failed";value->state="finishing";
        value->message=policy::bounded(data.value("message","Opération terminée."));
        value->prompt=nullptr;value->received_terminal=true;
      } else throw std::runtime_error("Événement interne non reconnu.");
    }
    void run(const std::shared_ptr<record> &value, const user_context &user) {
      std::string owner_tag="moonshine-job:"+value->id, secret;
      try {
        const auto [url,pin]=host.endpoint();secret=host.issue_token(owner_tag);
        if (secret.empty()) throw std::runtime_error("Impossible de préparer l’autorisation locale temporaire.");
        const auto sddl=wide("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x100002;;;"+user.sid+")");
        PSECURITY_DESCRIPTOR security=nullptr;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(),SDDL_REVISION_1,&security,nullptr)) throw std::runtime_error("Protection de l’annulation indisponible.");
        SECURITY_ATTRIBUTES event_sa {sizeof(SECURITY_ATTRIBUTES),security,FALSE};
        const auto event_name=wide("Global\\Moonshine.Sync."+value->id);
        SetLastError(ERROR_SUCCESS);HANDLE event=CreateEventW(&event_sa,TRUE,FALSE,event_name.c_str());const auto event_error=GetLastError();LocalFree(security);
        if (!event || event_error==ERROR_ALREADY_EXISTS) { if (event) CloseHandle(event);throw std::runtime_error("Événement d’annulation indisponible."); }
        { std::lock_guard guard(value->mutex);value->cancellation.value=event;if (value->cancel_requested) SetEvent(event); }
        SECURITY_ATTRIBUTES pipe_sa {sizeof(SECURITY_ATTRIBUTES),nullptr,TRUE};
        handle child_in, child_out, output;
        if (!CreatePipe(&child_in.value,&value->input.value,&pipe_sa,0) || !CreatePipe(&output.value,&child_out.value,&pipe_sa,0)) throw std::runtime_error("Canal interne indisponible.");
        if (!SetHandleInformation(value->input.value,HANDLE_FLAG_INHERIT,0) || !SetHandleInformation(output.value,HANDLE_FLAG_INHERIT,0)) throw std::runtime_error("Protection des canaux indisponible.");
        handle error(CreateFileW(L"NUL",GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&pipe_sa,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));
        if (error.value==INVALID_HANDLE_VALUE) throw std::runtime_error("Sortie interne indisponible.");
        STARTUPINFOEXW startup {};startup.StartupInfo.cb=sizeof(startup);startup.StartupInfo.dwFlags=STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput=child_in.value;startup.StartupInfo.hStdOutput=child_out.value;startup.StartupInfo.hStdError=error.value;
        SIZE_T bytes=0;InitializeProcThreadAttributeList(nullptr,1,0,&bytes);
        std::vector<unsigned char> attributes(bytes);startup.lpAttributeList=reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
        if (!InitializeProcThreadAttributeList(startup.lpAttributeList,1,0,&bytes)) throw std::runtime_error("Attributs du moteur indisponibles.");
        struct attribute_guard { LPPROC_THREAD_ATTRIBUTE_LIST p; ~attribute_guard() { DeleteProcThreadAttributeList(p); } } attr_guard {startup.lpAttributeList};
        HANDLE inherited[]={child_in.value,child_out.value,error.value};
        if (!UpdateProcThreadAttribute(startup.lpAttributeList,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,inherited,sizeof(inherited),nullptr,nullptr)) throw std::runtime_error("Héritage des canaux refusé.");
        wchar_t system_directory[MAX_PATH];if (!GetSystemDirectoryW(system_directory,MAX_PATH)) throw std::runtime_error("Windows PowerShell introuvable.");
        const auto powershell=std::filesystem::path(system_directory)/L"WindowsPowerShell/v1.0/powershell.exe";
        const auto script=host.package/L"Moonshine-Worker.ps1";
        const auto quoted=[](const std::filesystem::path &p) {const auto v=utf8(p.wstring());if (v.find_first_of("\"\r\n")!=std::string::npos) throw std::runtime_error("Chemin du moteur invalide.");return "\""+v+"\"";};
        const std::string command=quoted(powershell)+" -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "+quoted(script);
        PROCESS_INFORMATION process {};std::string error_message;
        if (!host.launch(command,host.package.wstring(),startup,process,error_message)) throw std::runtime_error("Démarrage dans le compte Windows impossible. "+policy::bounded(error_message,200));
        handle process_handle(process.hProcess), process_thread(process.hThread);
        CloseHandle(child_in.release());CloseHandle(child_out.release());
        auto boot=value->parameters;boot["protocol"]="moonshine-worker/1";boot["url"]=url;boot["pin"]=pin;boot["token"]=secret;
        boot["user_sid"]=user.sid;boot["cancel_event"]=utf8(event_name);
        { std::lock_guard guard(value->mutex);value->state="running";write_pipe(value->input.value,boot.dump()); }
        boot["token"]=nullptr;SecureZeroMemory(secret.data(),secret.size());secret.clear();
        char buffer[4096];std::string pending;DWORD count=0;
        while (ReadFile(output.value,buffer,sizeof(buffer),&count,nullptr) && count) {
          pending.append(buffer,count);if (pending.size()>8388608) throw std::runtime_error("Réponse interne trop volumineuse.");
          std::size_t newline;
          while ((newline=pending.find('\n'))!=std::string::npos) {
            auto line=pending.substr(0,newline);pending.erase(0,newline+1);if (!line.empty() && line.back()=='\r') line.pop_back();
            if (!line.empty()) apply_frame(value,line);
          }
        }
        if (!pending.empty()) throw std::runtime_error("Réponse interne tronquée; consulter le diagnostic.");
        WaitForSingleObject(process_handle.value,INFINITE);
        { std::lock_guard guard(value->mutex);
          if (!value->received_terminal) {value->outcome="failed";value->message="Le moteur s’est arrêté sans résultat confirmé. Les journaux permettent la reprise.";}
          value->state="finishing";
        }
      } catch (const std::exception &e) {
        std::lock_guard guard(value->mutex);if (value->cancellation.value) SetEvent(value->cancellation.value);
        value->outcome="failed";value->state="finishing";value->message=policy::bounded(e.what());value->prompt=nullptr;
      }
      if (!secret.empty()) SecureZeroMemory(secret.data(),secret.size());
      try { host.revoke_token(owner_tag); } catch (...) { }
      { std::lock_guard guard(value->mutex);if (value->input.value) CloseHandle(value->input.release());value->exited=true;value->state=value->outcome; }
      wake.notify_all();
    }
    json submit_impl(const json &request, bool internal) {
      if (!configured || stopping) throw std::runtime_error("Le moteur Moonshine n’est pas disponible.");
      const std::string action=request.value("action",""), scope=request.value("scope","all");
      if (!policy::action(action,internal) || !policy::scope(scope)) throw std::runtime_error("Action ou sélection invalide.");
      auto user=host.user();if (user.sid.empty() || !user.token) throw std::runtime_error("Ouvrez votre session Windows pour analyser la bibliothèque.");
      const auto value=std::make_shared<record>();value->id=random_id();value->owner=user.sid;value->action=action;
      value->parameters={{"action",action},{"scope",scope}};
      if (action=="profile") {
        const std::string game=request.value("game_id",""), mode=request.value("mode","");
        if (!policy::game_id(game) || !policy::mode(mode)) throw std::runtime_error("Profil ou jeu invalide.");
        value->parameters["game_id"]=game;value->parameters["mode"]=mode;
      }
      { std::lock_guard guard(manager_mutex);
        if (busy_locked()) throw std::runtime_error("Une opération est déjà en cours. Son résultat reste accessible.");
        records.push_back(value);active=value;while (records.size()>12) records.pop_front();
        try { value->thread=std::thread([value,user]() { run(value,user); }); }
        catch (...) { std::lock_guard record_guard(value->mutex);value->exited=true;value->state="failed";value->message="Le processus de travail ne peut pas démarrer.";throw; }
      }
      return public_record(value);
    }
  }
  void configure(host_services services) { std::lock_guard guard(manager_mutex);if (configured) return;host=std::move(services);configured=true; }
  json submit(const json &request) { return submit_impl(request,false); }
  json job(const std::string &id) { const auto user=host.user();std::lock_guard guard(manager_mutex);return public_record(find_locked(id,user.sid)); }
  json confirm(const std::string &id,const json &request) {
    const auto user=host.user();std::shared_ptr<record> value;
    { std::lock_guard guard(manager_mutex);value=find_locked(id,user.sid); }
    { std::lock_guard guard(value->mutex);
      if (value->state!="awaiting_confirmation" || !value->prompt.is_object()) throw std::runtime_error("Cette confirmation n’est plus active.");
      const bool accept=request.value("accept",false);const std::string nonce=request.value("nonce",""), text=request.value("text","");
      if (!policy::confirmation(value->prompt.value("nonce",""),nonce,value->prompt.value("typed",false),value->prompt.value("expected",""),text,accept)) throw std::runtime_error("Confirmation périmée ou texte incorrect.");
      write_pipe(value->input.value,json{{"answer",accept?value->prompt.value("expected",""):""}}.dump());
      value->prompt=nullptr;value->state="running";value->message="Vérification et application du plan…";
    }
    return public_record(value);
  }
  json cancel(const std::string &id) {
    const auto user=host.user();std::shared_ptr<record> value;
    { std::lock_guard guard(manager_mutex);value=find_locked(id,user.sid); }
    { std::lock_guard guard(value->mutex);
      if (!value->exited && !value->received_terminal) {
        value->cancel_requested=true;if (value->cancellation.value) SetEvent(value->cancellation.value);
        if (value->state=="awaiting_confirmation" && value->input.value) write_pipe(value->input.value,"{\"answer\":\"\"}");
        value->prompt=nullptr;value->state="cancelling";value->message="Annulation demandée; vérification de l’étape en cours avant l’arrêt.";
      }
    }
    return public_record(value);
  }
  json status() {
    json out={{"status",true},{"brand","Moonshine"},{"engine_version","0.8.0"},{"available",false},{"automatic",false},{"session_idle",false},{"job",nullptr},{"snapshot",nullptr}};
    if (!configured) return out;
    const auto user=host.user();if (user.sid.empty()) return out;
    out["available"]=true;out["automatic"]=auto_enabled(user);out["session_idle"]=host.idle();
    { std::lock_guard guard(manager_mutex);for (auto it=records.rbegin();it!=records.rend();++it) { if ((*it)->owner==user.sid) {out["job"]=public_record(*it);break;} } }
    auto snapshot=read_user_json(user,"moonshine-snapshot.json",8388608);
    if (snapshot.is_object() && snapshot.value("schema","")=="moonshine-snapshot/1" && snapshot.contains("games") && snapshot["games"].is_array()) {snapshot["cached"]=true;out["snapshot"]=std::move(snapshot);}
    return out;
  }
  void start() {
    std::lock_guard guard(manager_mutex);if (!configured || ticker.joinable()) return;stopping=false;
    ticker=std::thread([]() {
      std::string previous_sid;auto next=std::chrono::steady_clock::now()+std::chrono::minutes(1);
      while (!stopping) {
        { std::unique_lock lock(wake_mutex);wake.wait_for(lock,std::chrono::seconds(2),[] {return stopping.load();}); }
        if (stopping) break;
        try {
          const auto user=host.user();bool busy;
          { std::lock_guard lock(manager_mutex);busy=busy_locked();
            if (busy && active && active->owner!=user.sid) {std::lock_guard guard(active->mutex);active->cancel_requested=true;if (active->cancellation.value) SetEvent(active->cancellation.value);if (active->state=="awaiting_confirmation" && active->input.value) {write_pipe(active->input.value,"{\"answer\":\"\"}");active->prompt=nullptr;active->state="cancelling";}}
          }
          const auto now=std::chrono::steady_clock::now();
          if (user.sid!=previous_sid) {previous_sid=user.sid;next=now+std::chrono::minutes(1);}
          if (user.sid.empty() || now<next || busy) continue;
          if (policy::automatic_due(auto_enabled(user),busy,true,host.idle(),now,next)) { next=now+std::chrono::minutes(10);submit_impl({{"action","auto"},{"scope","all"}},true); }
        } catch (...) { }
      }
    });
  }
  void stop() {
    stopping=true;wake.notify_all();if (ticker.joinable()) ticker.join();
    std::deque<std::shared_ptr<record>> owned;
    {std::lock_guard guard(manager_mutex);owned=records;}
    for (const auto &value:owned) {std::lock_guard guard(value->mutex);value->cancel_requested=true;if (value->cancellation.value) SetEvent(value->cancellation.value);if (value->state=="awaiting_confirmation" && value->input.value) {try {write_pipe(value->input.value,"{\"answer\":\"\"}");} catch (...) {}}}
    for (const auto &value:owned) if (value->thread.joinable()) value->thread.join();
  }
}
#else
namespace moonshine {
  void start() {} void stop() {}
  json status() {return {{"status",true},{"brand","Moonshine"},{"available",false},{"message","Synchronisation Xbox PC disponible sous Windows."}};}
  json submit(const json &) {throw std::runtime_error("Windows requis.");}
  json job(const std::string &) {throw std::runtime_error("Windows requis.");}
  json confirm(const std::string &,const json &) {throw std::runtime_error("Windows requis.");}
  json cancel(const std::string &) {throw std::runtime_error("Windows requis.");}
}
#endif
