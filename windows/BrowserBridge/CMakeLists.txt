cmake_minimum_required(VERSION 3.14)
project(browser_bridge LANGUAGES CXX)

# caocode-browser-host.exe, the browsers' native messaging host (host.cpp).
# It goes beside caocode.exe with dev.baocode.browser.json, the manifest
# the browsers find it by: the installer's keys point there (see
# tool/caocode.iss), and its "path", relative, is the host beside it.
add_executable(caocode-browser-host "host.cpp")
apply_standard_settings(caocode-browser-host)
target_compile_options(caocode-browser-host PRIVATE /utf-8)
target_compile_definitions(caocode-browser-host PRIVATE
  "NOMINMAX" "WIN32_LEAN_AND_MEAN")
target_link_libraries(caocode-browser-host PRIVATE "ws2_32.lib")
