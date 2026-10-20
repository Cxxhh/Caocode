// caocode-browser-host.exe: the native messaging host of Caocode's browser
// extension (browser_extension/) on Windows, as macos/BrowserBridge/host.c
// is on macOS. The browser starts it for the extension, as
// dev.baocode.browser.json beside it says (the installer's keys point the
// browsers there, see tool/caocode.iss). It passes the extension's
// messages to Caocode and Caocode's back: waiting for Caocode while it is
// not running, and again once it quits.
//
// Dart has no Unix sockets on Windows: Caocode (lib/browser/
// browser_bridge.dart) listens on 127.0.0.1, at the port its file in the
// user's temporary folder says, caocode-browser.port: "<port> <token>".
// Any program may connect there, so the host's hello says the token, which
// only the user can read; Caocode lets in no one who does not.
//
// Both ways a message is the browser's: its length (4 bytes, this
// machine's order), then that much JSON. The host says what goes on with
// Caocode in messages of its own: {"type":"bridge","connected":…}. It
// quits once the browser lets it go (its input ends).

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_MESSAGE (64 * 1024 * 1024)

static SRWLOCK out_lock = SRWLOCK_INIT;
static SRWLOCK socket_lock = SRWLOCK_INIT;
static SOCKET bao = INVALID_SOCKET;  // The socket to Caocode, while connected.
static const char* origin = "";
static HANDLE input;
static HANDLE output;

// The browser's input and output: pipes, read and written as they are (no
// text mode's line ends).
static bool read_input(void* buffer, uint32_t size) {
  char* p = static_cast<char*>(buffer);
  while (size > 0) {
    DWORD n = 0;
    if (!ReadFile(input, p, size, &n, nullptr) || n == 0) return false;
    p += n;
    size -= n;
  }
  return true;
}

static bool write_output(const void* buffer, uint32_t size) {
  const char* p = static_cast<const char*>(buffer);
  while (size > 0) {
    DWORD n = 0;
    if (!WriteFile(output, p, size, &n, nullptr) || n == 0) return false;
    p += n;
    size -= n;
  }
  return true;
}

static bool receive_all(SOCKET fd, void* buffer, uint32_t size) {
  char* p = static_cast<char*>(buffer);
  while (size > 0) {
    int n = recv(fd, p, static_cast<int>(size), 0);
    if (n <= 0) return false;
    p += n;
    size -= static_cast<uint32_t>(n);
  }
  return true;
}

static bool send_all(SOCKET fd, const void* buffer, uint32_t size) {
  const char* p = static_cast<const char*>(buffer);
  while (size > 0) {
    int n = send(fd, p, static_cast<int>(size), 0);
    if (n <= 0) return false;
    p += n;
    size -= static_cast<uint32_t>(n);
  }
  return true;
}

// A whole message, by [take]: its text (freed by the caller), nullptr once
// the input ends.
template <typename Take>
static char* read_message(Take take, uint32_t* length) {
  if (!take(length, 4) || *length > MAX_MESSAGE) return nullptr;
  char* text = static_cast<char*>(malloc(*length ? *length : 1));
  if (!text) return nullptr;
  if (!take(text, *length)) {
    free(text);
    return nullptr;
  }
  return text;
}

static bool send_message(SOCKET fd, const char* text, uint32_t length) {
  return send_all(fd, &length, 4) && send_all(fd, text, length);
}

// To the extension, whole messages at a time.
static void to_browser(const char* text, uint32_t length) {
  AcquireSRWLockExclusive(&out_lock);
  if (!write_output(&length, 4) || !write_output(text, length)) ExitProcess(0);
  ReleaseSRWLockExclusive(&out_lock);
}

static void tell_browser(bool connected) {
  const char* text = connected ? "{\"type\":\"bridge\",\"connected\":true}"
                               : "{\"type\":\"bridge\",\"connected\":false}";
  to_browser(text, static_cast<uint32_t>(strlen(text)));
}

// Caocode's port and token, from its file: false while there is none
// (Caocode is not running) or it is not whole yet.
static bool find_bao(unsigned* port, char* token, size_t size) {
  wchar_t path[MAX_PATH + 32];
  const DWORD n = GetTempPathW(MAX_PATH + 1, path);
  if (n == 0 || n > MAX_PATH) return false;
  if (wcscat_s(path, L"caocode-browser.port") != 0) return false;
  HANDLE file = CreateFileW(
      path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  char text[256];
  DWORD got = 0;
  const BOOL ok = ReadFile(file, text, static_cast<DWORD>(sizeof text - 1),
                           &got, nullptr);
  CloseHandle(file);
  if (!ok) return false;
  text[got] = 0;
  char* end = nullptr;
  const unsigned long value = strtoul(text, &end, 10);
  if (end == text || *end != ' ' || value == 0 || value > 65535) return false;
  // The token is hex: nothing in it needs escaping in the hello's JSON.
  const char* given = end + 1;
  const size_t length = strspn(given, "0123456789abcdef");
  if (length == 0 || length >= size || given[length] != 0) return false;
  memcpy(token, given, length);
  token[length] = 0;
  *port = static_cast<unsigned>(value);
  return true;
}

static SOCKET connect_bao(unsigned port) {
  SOCKET fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (fd == INVALID_SOCKET) return INVALID_SOCKET;
  sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_port = htons(static_cast<u_short>(port));
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, reinterpret_cast<sockaddr*>(&address),
              static_cast<int>(sizeof address)) != 0) {
    closesocket(fd);
    return INVALID_SOCKET;
  }
  return fd;
}

// Caocode's messages, to the browser; connecting again each time Caocode
// comes back.
static DWORD WINAPI from_bao(void*) {
  for (;;) {
    unsigned port = 0;
    char token[128];
    if (!find_bao(&port, token, sizeof token)) {
      Sleep(1000);
      continue;
    }
    SOCKET fd = connect_bao(port);
    if (fd == INVALID_SOCKET) {
      Sleep(1000);
      continue;
    }
    // Who it is: the extension's origin, as the browser gave it, and the
    // token, which says the host is one the user started.
    char hello[640];
    const int n = snprintf(hello, sizeof hello,
                           "{\"type\":\"hello\",\"origin\":\"%s\","
                           "\"token\":\"%s\"}",
                           origin, token);
    if (n <= 0 || n >= static_cast<int>(sizeof hello) ||
        !send_message(fd, hello, static_cast<uint32_t>(n))) {
      closesocket(fd);
      Sleep(1000);
      continue;
    }
    AcquireSRWLockExclusive(&socket_lock);
    bao = fd;
    ReleaseSRWLockExclusive(&socket_lock);
    tell_browser(true);
    for (;;) {
      uint32_t length;
      char* text = read_message(
          [fd](void* buffer, uint32_t size) {
            return receive_all(fd, buffer, size);
          },
          &length);
      if (!text) break;
      to_browser(text, length);
      free(text);
    }
    AcquireSRWLockExclusive(&socket_lock);
    bao = INVALID_SOCKET;
    ReleaseSRWLockExclusive(&socket_lock);
    closesocket(fd);
    tell_browser(false);
    Sleep(1000);
  }
}

int main(int argc, char** argv) {
  // The browser's: the extension's origin first, then a window's handle
  // (--parent-window=…).
  for (int i = 1; i < argc; i++) {
    if (strncmp(argv[i], "chrome-extension://", 19) == 0) {
      // Quotes and backslashes have no place in an origin: none is let in
      // the JSON it goes into.
      if (!strpbrk(argv[i], "\"\\")) origin = argv[i];
      break;
    }
  }
  input = GetStdHandle(STD_INPUT_HANDLE);
  output = GetStdHandle(STD_OUTPUT_HANDLE);
  WSADATA wsa;
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 1;
  tell_browser(false);
  HANDLE thread = CreateThread(nullptr, 0, from_bao, nullptr, 0, nullptr);
  if (!thread) return 1;
  CloseHandle(thread);
  // The extension's messages, to Caocode: dropped while it is not there
  // (the extension knows, told above).
  for (;;) {
    uint32_t length;
    char* text = read_message(read_input, &length);
    if (!text) ExitProcess(0);
    AcquireSRWLockExclusive(&socket_lock);
    if (bao != INVALID_SOCKET && !send_message(bao, text, length)) {
      // Gone: its reader sees it too, and says so.
      shutdown(bao, SD_BOTH);
    }
    ReleaseSRWLockExclusive(&socket_lock);
    free(text);
  }
}
