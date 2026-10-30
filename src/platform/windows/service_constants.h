#pragma once

namespace platf::service_launch {
#ifdef MOONSHINE_HOST
  inline constexpr char name[] = "MoonshineService";
  inline constexpr wchar_t wide_name[] = L"MoonshineService";
#else
  inline constexpr char name[] = "SunshineService";
  inline constexpr wchar_t wide_name[] = L"SunshineService";
#endif
  inline constexpr wchar_t launched_by_service_env_var[] = L"SUNSHINE_LAUNCHED_BY_SERVICE";
}
