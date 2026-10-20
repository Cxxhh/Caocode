cmake_minimum_required(VERSION 3.13)
project(browser_bridge LANGUAGES C)

# caocode-browser-host, the browsers' native messaging host: macOS's
# (macos/BrowserBridge/host.c), built here too. It goes beside caocode,
# where BrowserBridge.hostExecutable finds it, and the manifests Caocode
# writes in each browser's folder name it there.
find_package(Threads REQUIRED)
add_executable(caocode-browser-host
  "${CMAKE_CURRENT_SOURCE_DIR}/../../macos/BrowserBridge/host.c")
target_compile_options(caocode-browser-host PRIVATE -Wall -Wextra -Werror)
target_compile_options(caocode-browser-host PRIVATE
  "$<$<NOT:$<CONFIG:Debug>>:-O2>")
target_link_libraries(caocode-browser-host PRIVATE Threads::Threads)
