/**
 * @file tools/sunshinesvc.cpp
 * @brief Handles launching Sunshine.exe into user sessions as SYSTEM
 */
#define WIN32_LEAN_AND_MEAN
#include <format>
#include <string>
#include <filesystem>
#include <fstream>
#include <cstdio>
#include <Windows.h>
#include <WtsApi32.h>

#include "src/platform/windows/service_constants.h"

// PROC_THREAD_ATTRIBUTE_JOB_LIST is currently missing from MinGW headers
#ifndef PROC_THREAD_ATTRIBUTE_JOB_LIST
  #define PROC_THREAD_ATTRIBUTE_JOB_LIST ProcThreadAttributeValue(13, FALSE, TRUE, FALSE)
#endif

SERVICE_STATUS_HANDLE service_status_handle;
SERVICE_STATUS service_status;
HANDLE stop_event;
HANDLE session_change_event;

constexpr auto SERVICE_NAME = platf::service_launch::name;
constexpr DWORD FAST_EXIT_WINDOW_MS = 60 * 1000;
constexpr DWORD CRASH_LOOP_RESTART_DELAY_MS = 30 * 1000;
constexpr DWORD CRASH_LOOP_FAST_EXIT_THRESHOLD = 3;

#ifdef MOONSHINE_HOST
std::filesystem::path ServicePackageRoot() {
  std::wstring name(32768,L'\0');
  const auto size=GetModuleFileNameW(nullptr,name.data(),static_cast<DWORD>(name.size()));
  if (!size || size>=name.size()) ExitProcess(ERROR_BAD_PATHNAME);
  name.resize(size);return std::filesystem::path(name).parent_path().parent_path();
}
void LogService(HANDLE log,const std::string &message,DWORD error=0) {
  const auto text=std::format("{}: {} (Windows {})\r\n",GetTickCount64(),message,error);
  DWORD written=0;WriteFile(log,text.data(),static_cast<DWORD>(text.size()),&written,nullptr);
}
#endif

DWORD WINAPI HandlerEx(DWORD dwControl, DWORD dwEventType, LPVOID lpEventData, LPVOID lpContext) {
  switch (dwControl) {
    case SERVICE_CONTROL_INTERROGATE:
      return NO_ERROR;

    case SERVICE_CONTROL_SESSIONCHANGE:
      // If a new session connects to the console, restart Sunshine
      // to allow it to spawn inside the new console session.
      if (dwEventType == WTS_CONSOLE_CONNECT) {
        SetEvent(session_change_event);
      }
      return NO_ERROR;

    case SERVICE_CONTROL_PRESHUTDOWN:
      // The system is shutting down
    case SERVICE_CONTROL_STOP:
      // Let SCM know we're stopping in up to 30 seconds
      service_status.dwCurrentState = SERVICE_STOP_PENDING;
      service_status.dwControlsAccepted = 0;
      service_status.dwWaitHint = 30 * 1000;
      SetServiceStatus(service_status_handle, &service_status);

      // Trigger ServiceMain() to start cleanup
      SetEvent(stop_event);
      return NO_ERROR;

    default:
      return ERROR_CALL_NOT_IMPLEMENTED;
  }
}

HANDLE CreateJobObjectForChildProcess() {
  HANDLE job_handle = CreateJobObjectW(nullptr, nullptr);
  if (!job_handle) {
    return nullptr;
  }

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION job_limit_info = {};

  // Kill Sunshine.exe when the final job object handle is closed (which will happen if we terminate unexpectedly).
  // This ensures we don't leave an orphaned Sunshine.exe running with an inherited handle to our log file.
  job_limit_info.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

  // Allow Sunshine.exe to use CREATE_BREAKAWAY_FROM_JOB when spawning processes to ensure they can to live beyond
  // the lifetime of SunshineSvc.exe. This avoids unexpected user data loss if we crash or are killed.
  job_limit_info.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_BREAKAWAY_OK;

  if (!SetInformationJobObject(job_handle, JobObjectExtendedLimitInformation, &job_limit_info, sizeof(job_limit_info))) {
    CloseHandle(job_handle);
    return nullptr;
  }

  return job_handle;
}

LPPROC_THREAD_ATTRIBUTE_LIST AllocateProcThreadAttributeList(DWORD attribute_count) {
  SIZE_T size;
  InitializeProcThreadAttributeList(nullptr, attribute_count, 0, &size);

  auto list = (LPPROC_THREAD_ATTRIBUTE_LIST) HeapAlloc(GetProcessHeap(), 0, size);
  if (list == nullptr) {
    return nullptr;
  }

  if (!InitializeProcThreadAttributeList(list, attribute_count, 0, &size)) {
    HeapFree(GetProcessHeap(), 0, list);
    return nullptr;
  }

  return list;
}

HANDLE DuplicateTokenForSession(DWORD console_session_id) {
  HANDLE current_token;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE, &current_token)) {
    return nullptr;
  }

  // Duplicate our own LocalSystem token
  HANDLE new_token;
  if (!DuplicateTokenEx(current_token, TOKEN_ALL_ACCESS, nullptr, SecurityImpersonation, TokenPrimary, &new_token)) {
    CloseHandle(current_token);
    return nullptr;
  }

  CloseHandle(current_token);

  // Change the duplicated token to the console session ID
  if (!SetTokenInformation(new_token, TokenSessionId, &console_session_id, sizeof(console_session_id))) {
    CloseHandle(new_token);
    return nullptr;
  }

  return new_token;
}

HANDLE OpenLogFileHandle() {
#ifdef MOONSHINE_HOST
  const auto path=ServicePackageRoot()/L"config/service.log";
  auto log=CreateFileW(path.c_str(),FILE_APPEND_DATA,FILE_SHARE_READ,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
  return log;
#else
  WCHAR log_file_name[MAX_PATH];

  // Create sunshine.log in the Temp folder (usually %SYSTEMROOT%\Temp)
  GetTempPathW(_countof(log_file_name), log_file_name);
  wcscat_s(log_file_name, L"sunshine.log");

  // The file handle must be inheritable for our child process to use it
  SECURITY_ATTRIBUTES security_attributes = {sizeof(security_attributes), nullptr, TRUE};

  // Overwrite the old sunshine.log
  return CreateFileW(log_file_name, GENERIC_WRITE, FILE_SHARE_READ, &security_attributes, CREATE_ALWAYS, 0, nullptr);
#endif
}

bool RunTerminationHelper(HANDLE console_token, DWORD pid) {
#ifdef MOONSHINE_HOST
  // A named event crosses sessions without inheriting SCM handles or needing a console.
  std::ifstream input(ServicePackageRoot()/L"moonshine-trial-id.txt",std::ios::binary);
  std::string id;std::getline(input,id);
  if (!id.empty() && id.back()=='\r') id.pop_back();
  if (id.size()!=32 || id.find_first_not_of("0123456789abcdef")!=std::string::npos) return false;
  const std::wstring name=L"Global\\Moonshine.Service.Stop."+std::wstring(id.begin(),id.end());
  const auto event=OpenEventW(EVENT_MODIFY_STATE,FALSE,name.c_str());
  if (!event) return false;const bool signalled=SetEvent(event)!=FALSE;CloseHandle(event);return signalled;
#else
  WCHAR module_path[MAX_PATH];
  GetModuleFileNameW(nullptr, module_path, _countof(module_path));
  std::wstring command;

  command += L'"';
  command += module_path;
  command += L'"';
  command += std::format(L" --terminate {}", pid);

  STARTUPINFOW startup_info = {};
  startup_info.cb = sizeof(startup_info);
  startup_info.lpDesktop = (LPWSTR) L"winsta0\\default";

  // Execute ourselves as a detached process in the user session with the --terminate argument.
  // This will allow us to attach to Sunshine's console and send it a Ctrl-C event.
  PROCESS_INFORMATION process_info;
  if (!CreateProcessAsUserW(console_token, module_path, (LPWSTR) command.c_str(), nullptr, nullptr, FALSE, CREATE_UNICODE_ENVIRONMENT | DETACHED_PROCESS, nullptr, nullptr, &startup_info, &process_info)) {
    return false;
  }

  // Wait for the termination helper to complete
  WaitForSingleObject(process_info.hProcess, INFINITE);

  // Check the exit status of the helper process
  DWORD exit_code;
  GetExitCodeProcess(process_info.hProcess, &exit_code);

  // Cleanup handles
  CloseHandle(process_info.hProcess);
  CloseHandle(process_info.hThread);

  // If the helper process returned 0, it succeeded
  return exit_code == 0;
#endif
}

void ReportServiceStopped(DWORD error, HANDLE log_file_handle = INVALID_HANDLE_VALUE, LPPROC_THREAD_ATTRIBUTE_LIST attributes = nullptr) {
  // SERVICE_STOPPED permits SCM to start a replacement immediately. Release our
  // non-write-shared log handle before publishing that state, including failures
  // during startup; returning from ServiceMain does not release process handles.
  if (attributes != nullptr) {
    DeleteProcThreadAttributeList(attributes);
    HeapFree(GetProcessHeap(), 0, attributes);
  }
  if (log_file_handle != INVALID_HANDLE_VALUE) {
    CloseHandle(log_file_handle);
  }
  // HandlerEx remains registered until process exit. Its event handles must
  // stay valid for any control callback already in flight during cleanup.
  service_status.dwControlsAccepted = 0;
  service_status.dwCheckPoint = 0;
  service_status.dwWaitHint = 0;
  service_status.dwWin32ExitCode = error;
  service_status.dwCurrentState = SERVICE_STOPPED;
  SetServiceStatus(service_status_handle, &service_status);
}

VOID WINAPI ServiceMain(DWORD dwArgc, LPTSTR *lpszArgv) {
  service_status_handle = RegisterServiceCtrlHandlerEx(SERVICE_NAME, HandlerEx, nullptr);
  if (service_status_handle == nullptr) {
    // Nothing we can really do here but terminate ourselves
    ExitProcess(GetLastError());
    return;
  }

  // Tell SCM we're starting
  service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  service_status.dwServiceSpecificExitCode = 0;
  service_status.dwWin32ExitCode = NO_ERROR;
  service_status.dwWaitHint = 0;
  service_status.dwControlsAccepted = 0;
  service_status.dwCheckPoint = 0;
  service_status.dwCurrentState = SERVICE_START_PENDING;
  SetServiceStatus(service_status_handle, &service_status);

  // Create a manual-reset stop event
  stop_event = CreateEventA(nullptr, TRUE, FALSE, nullptr);
  if (stop_event == nullptr) {
    // Tell SCM we failed to start
    ReportServiceStopped(GetLastError());
    return;
  }

  // Create an auto-reset session change event
  session_change_event = CreateEventA(nullptr, FALSE, FALSE, nullptr);
  if (session_change_event == nullptr) {
    // Tell SCM we failed to start
    ReportServiceStopped(GetLastError());
    return;
  }

  auto log_file_handle = OpenLogFileHandle();
  if (log_file_handle == INVALID_HANDLE_VALUE) {
    // Tell SCM we failed to start
    ReportServiceStopped(GetLastError());
    return;
  }

  // We can use a single STARTUPINFOEXW for all the processes that we launch
  STARTUPINFOEXW startup_info = {};
  startup_info.StartupInfo.cb = sizeof(startup_info);
  startup_info.StartupInfo.lpDesktop = (LPWSTR) L"winsta0\\default";
#ifndef MOONSHINE_HOST
  startup_info.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup_info.StartupInfo.hStdInput = nullptr;
  startup_info.StartupInfo.hStdOutput = log_file_handle;
  startup_info.StartupInfo.hStdError = log_file_handle;
#endif

  // Allocate an attribute list with space for 2 entries
  startup_info.lpAttributeList = AllocateProcThreadAttributeList(2);
  if (startup_info.lpAttributeList == nullptr) {
    // Tell SCM we failed to start
    ReportServiceStopped(GetLastError(), log_file_handle);
    return;
  }

  // Only allow Sunshine.exe to inherit the log file handle, not all inheritable handles
#ifndef MOONSHINE_HOST
  UpdateProcThreadAttribute(startup_info.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &log_file_handle, sizeof(log_file_handle), nullptr, nullptr);
#endif

  // Tell SCM we're running (and stoppable now)
  service_status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_PRESHUTDOWN | SERVICE_ACCEPT_SESSIONCHANGE;
  service_status.dwCurrentState = SERVICE_RUNNING;
  SetServiceStatus(service_status_handle, &service_status);

  SetEnvironmentVariableW(platf::service_launch::launched_by_service_env_var, L"1");

  DWORD fast_exit_count = 0;
  ULONGLONG first_fast_exit_tick = 0;

  // Loop every 3 seconds until the stop event is set or Sunshine.exe is running
  while (WaitForSingleObject(stop_event, 3000) != WAIT_OBJECT_0) {
    auto console_session_id = WTSGetActiveConsoleSessionId();
    if (console_session_id == 0xFFFFFFFF) {
      // No console session yet
      continue;
    }

    auto console_token = DuplicateTokenForSession(console_session_id);
    if (console_token == nullptr) {
      continue;
    }

    // Job objects cannot span sessions, so we must create one for each process
    auto job_handle = CreateJobObjectForChildProcess();
    if (job_handle == nullptr) {
      CloseHandle(console_token);
      continue;
    }

    // Start Sunshine.exe inside our job object
    UpdateProcThreadAttribute(startup_info.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST, &job_handle, sizeof(job_handle), nullptr, nullptr);

    PROCESS_INFORMATION process_info;
#ifdef MOONSHINE_HOST
    const auto root=ServicePackageRoot();const auto executable=root/L"sunshine.exe";
    auto command=L"\""+executable.wstring()+L"\" \""+(root/L"config/moonshine.conf").wstring()+L"\"";
    const bool launched=CreateProcessAsUserW(console_token,executable.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_UNICODE_ENVIRONMENT|CREATE_NO_WINDOW|EXTENDED_STARTUPINFO_PRESENT,nullptr,root.c_str(),(LPSTARTUPINFOW)&startup_info,&process_info)!=FALSE;
    if (!launched) LogService(log_file_handle,"Host launch failed",GetLastError());
#else
    const bool launched=CreateProcessAsUserW(console_token, L"Sunshine.exe", nullptr, nullptr, nullptr, TRUE, CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT, nullptr, nullptr, (LPSTARTUPINFOW) &startup_info, &process_info)!=FALSE;
#endif
    if (!launched) {
      CloseHandle(console_token);
      CloseHandle(job_handle);
      continue;
    }
#ifdef MOONSHINE_HOST
    LogService(log_file_handle,"Host started in console session "+std::to_string(console_session_id));
#endif

    bool still_running = true;
    bool self_exit = false;
    const auto process_start_tick = GetTickCount64();
    do {
      // Wait for the stop event to be set, Sunshine.exe to terminate, or the console session to change
      const HANDLE wait_objects[] = {stop_event, process_info.hProcess, session_change_event};
      switch (WaitForMultipleObjects(_countof(wait_objects), wait_objects, FALSE, INFINITE)) {
        case WAIT_OBJECT_0 + 2:
          if (WTSGetActiveConsoleSessionId() == console_session_id) {
            // The active console session didn't actually change. Let Sunshine keep running.
            still_running = true;
            continue;
          }
          // Fall-through to terminate Sunshine.exe and start it again.
        case WAIT_OBJECT_0:
          // The service is shutting down, so try to gracefully terminate Sunshine.exe.
          // If it doesn't terminate in 20 seconds, we will forcefully terminate it.
          if (!RunTerminationHelper(console_token, process_info.dwProcessId) ||
              WaitForSingleObject(process_info.hProcess, 20000) != WAIT_OBJECT_0) {
            // If it won't terminate gracefully, kill it now
            if (!TerminateProcess(process_info.hProcess, ERROR_PROCESS_ABORTED)) {
              const auto termination_error = GetLastError();
              // Termination can fail when the child has already exited. Otherwise
              // fail the service instead of waiting forever or reporting success;
              // process exit also closes our kill-on-close job as a last resort.
              if (WaitForSingleObject(process_info.hProcess, 0) != WAIT_OBJECT_0) {
                ExitProcess(termination_error);
                return;
              }
            }
            // TerminateProcess is asynchronous. The inherited log handle stays
            // open until termination completes, so wait before allowing restart.
            if (WaitForSingleObject(process_info.hProcess, INFINITE) != WAIT_OBJECT_0) {
              ExitProcess(GetLastError());
              return;
            }
          }
          still_running = false;
          break;

        case WAIT_OBJECT_0 + 1:
          {
            // Sunshine terminated itself.
            self_exit = true;

            DWORD exit_code;
            if (GetExitCodeProcess(process_info.hProcess, &exit_code) && exit_code == ERROR_SHUTDOWN_IN_PROGRESS) {
              // Sunshine is asking for us to shut down, so gracefully stop ourselves.
              SetEvent(stop_event);
            }
            still_running = false;
            break;
          }
      }
    } while (still_running);

    CloseHandle(process_info.hThread);
    CloseHandle(process_info.hProcess);
    CloseHandle(console_token);
    CloseHandle(job_handle);

    if (!self_exit) {
      fast_exit_count = 0;
      first_fast_exit_tick = 0;
      continue;
    }

    const auto now_tick = GetTickCount64();
    if (now_tick - process_start_tick > FAST_EXIT_WINDOW_MS) {
      fast_exit_count = 0;
      first_fast_exit_tick = 0;
      continue;
    }

    if (first_fast_exit_tick == 0 || now_tick - first_fast_exit_tick > FAST_EXIT_WINDOW_MS) {
      first_fast_exit_tick = now_tick;
      fast_exit_count = 1;
    } else {
      ++fast_exit_count;
    }

    if (fast_exit_count >= CRASH_LOOP_FAST_EXIT_THRESHOLD) {
      if (WaitForSingleObject(stop_event, CRASH_LOOP_RESTART_DELAY_MS) == WAIT_OBJECT_0) {
        break;
      }
    }
  }

  // The child has exited; release our remaining handles before allowing restart.
  ReportServiceStopped(NO_ERROR, log_file_handle, startup_info.lpAttributeList);
}

// This will run in a child process in the user session
int DoGracefulTermination(DWORD pid) {
  // Attach to Sunshine's console
  if (!AttachConsole(pid)) {
    return GetLastError();
  }

  // Disable our own Ctrl-C handling
  SetConsoleCtrlHandler(nullptr, TRUE);

  // Send a Ctrl-C event to Sunshine
  if (!GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0)) {
    return GetLastError();
  }

  return 0;
}

int main(int argc, char *argv[]) {
#ifdef MOONSHINE_HOST
  SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_APPLICATION_DIR|LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (argc==2 && std::string(argv[1])=="--identity") { std::puts(SERVICE_NAME);return 0; }
#endif
  static const SERVICE_TABLE_ENTRY service_table[] = {
    {(LPSTR) SERVICE_NAME, ServiceMain},
    {nullptr, nullptr}
  };

  // Check if this is a reinvocation of ourselves to send Ctrl-C to Sunshine.exe
  if (argc == 3 && strcmp(argv[1], "--terminate") == 0) {
    return DoGracefulTermination(atol(argv[2]));
  }

  // By default, services have their current directory set to %SYSTEMROOT%\System32.
  // We want to use the directory where Sunshine.exe is located instead of system32.
  // This requires stripping off 2 path components: the file name and the last folder
  WCHAR module_path[MAX_PATH];
  GetModuleFileNameW(nullptr, module_path, _countof(module_path));
  for (auto i = 0; i < 2; i++) {
    auto last_sep = wcsrchr(module_path, '\\');
    if (last_sep) {
      *last_sep = 0;
    }
  }
  SetCurrentDirectoryW(module_path);

  // Trigger our ServiceMain()
  return StartServiceCtrlDispatcher(service_table)?0:static_cast<int>(GetLastError());
}
