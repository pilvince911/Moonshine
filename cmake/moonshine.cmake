# Moonshine additions. Upstream capture/encoder dependencies remain authoritative.
list(APPEND SUNSHINE_TARGET_FILES
    "${CMAKE_SOURCE_DIR}/src/confighttp_moonshine.cpp"
    "${CMAKE_SOURCE_DIR}/src/moonshine/bridge_windows.cpp"
    "${CMAKE_SOURCE_DIR}/src/moonshine/bridge.h"
    "${CMAKE_SOURCE_DIR}/src/moonshine/policy.h")
list(APPEND SUNSHINE_DEFINITIONS MOONSHINE_HOST=1)
install(DIRECTORY "${CMAKE_SOURCE_DIR}/tools/moonshine/"
    DESTINATION "tools/moonshine" COMPONENT application)
