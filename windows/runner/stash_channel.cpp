#include "stash_channel.h"

#include <flutter/standard_method_codec.h>

#include <cstdlib>
#include <sstream>
#include <thread>

#include "app_windows.h"
#include "stash_ocr.h"
#include "utils.h"

namespace {

// The hot key's id on the main window (WM_HOTKEY's wparam).
constexpr int kHotkeyId = 0x4253;  // 'BS'

std::string Lower(std::string text) {
  for (char& c : text) {
    if (c >= 'A' && c <= 'Z') {
      c = static_cast<char>(c - 'A' + 'a');
    }
  }
  return text;
}

std::string Trim(const std::string& text) {
  const size_t start = text.find_first_not_of(" \t");
  if (start == std::string::npos) {
    return std::string();
  }
  const size_t end = text.find_last_not_of(" \t");
  return text.substr(start, end - start + 1);
}

// The virtual key |name| (`a`, `space`, `f5`, `/`…) stands for; 0 for none.
UINT KeyOf(const std::string& name) {
  if (name.size() == 1) {
    const char c = name[0];
    if (c >= 'a' && c <= 'z') {
      return static_cast<UINT>(c - 'a' + 'A');
    }
    if (c >= '0' && c <= '9') {
      return static_cast<UINT>(c);
    }
    // Punctuation, as the keyboard's layout has it.
    const SHORT scan = ::VkKeyScanW(static_cast<wchar_t>(c));
    return scan == -1 ? 0 : static_cast<UINT>(LOBYTE(scan));
  }
  static const std::pair<const char*, UINT> kNamed[] = {
      {"space", VK_SPACE},   {"enter", VK_RETURN}, {"return", VK_RETURN},
      {"tab", VK_TAB},       {"escape", VK_ESCAPE}, {"esc", VK_ESCAPE},
      {"left", VK_LEFT},     {"right", VK_RIGHT},  {"up", VK_UP},
      {"down", VK_DOWN},     {"backquote", VK_OEM_3},
  };
  for (const auto& [named, key] : kNamed) {
    if (name == named) {
      return key;
    }
  }
  if (name.size() >= 2 && name[0] == 'f') {
    const int number = std::atoi(name.c_str() + 1);
    if (number >= 1 && number <= 24) {
      return static_cast<UINT>(VK_F1 + number - 1);
    }
  }
  return 0;
}

}  // namespace

StashChannel::StashChannel(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window),
      channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "caocode/stash",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

StashChannel::~StashChannel() {
  channel_->SetMethodCallHandler(nullptr);
  Unregister();
}

std::optional<std::pair<UINT, UINT>> StashChannel::Parse(
    const std::string& spec) {
  UINT modifiers = 0;
  UINT key = 0;
  std::stringstream parts(Lower(spec));
  std::string part;
  while (std::getline(parts, part, '+')) {
    part = Trim(part);
    if (part == "ctrl" || part == "control") {
      modifiers |= MOD_CONTROL;
    } else if (part == "alt" || part == "option" || part == "opt") {
      modifiers |= MOD_ALT;
    } else if (part == "shift") {
      modifiers |= MOD_SHIFT;
    } else if (part == "cmd" || part == "command" || part == "meta" ||
               part == "win" || part == "super") {
      modifiers |= MOD_WIN;
    } else if (!part.empty()) {
      key = KeyOf(part);
    }
  }
  if (key == 0 || modifiers == 0) {
    return std::nullopt;
  }
  return std::make_pair(modifiers, key);
}

bool StashChannel::Register(const std::string& spec) {
  Unregister();
  const auto parsed = Parse(spec);
  if (!parsed) {
    return Trim(spec).empty();
  }
  registered_ = ::RegisterHotKey(window_, kHotkeyId,
                                 parsed->first | MOD_NOREPEAT,
                                 parsed->second) != 0;
  return registered_;
}

void StashChannel::Unregister() {
  if (registered_) {
    ::UnregisterHotKey(window_, kHotkeyId);
    registered_ = false;
  }
}

void StashChannel::Post(HWND window, std::function<void()> task) {
  auto* boxed = new std::function<void()>(std::move(task));
  if (!::PostMessageW(window, kRunMessage, 0,
                      reinterpret_cast<LPARAM>(boxed))) {
    delete boxed;
  }
}

void StashChannel::Run(LPARAM task, bool alive) {
  std::unique_ptr<std::function<void()>> boxed(
      reinterpret_cast<std::function<void()>*>(task));
  if (alive && boxed != nullptr && *boxed) {
    (*boxed)();
  }
}

bool StashChannel::HandleHotkey(WPARAM id) {
  if (static_cast<int>(id) != kHotkeyId) {
    return false;
  }
  const HWND front = ::GetForegroundWindow();
  DWORD process = 0;
  if (front != nullptr) {
    ::GetWindowThreadProcessId(front, &process);
  }
  // The panel itself in front: it hides (given the keyboard back
  // otherwise).
  channel_->InvokeMethod(
      "pressed",
      std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
          {flutter::EncodableValue("self"),
           flutter::EncodableValue(front != nullptr &&
                                   process == ::GetCurrentProcessId())},
          {flutter::EncodableValue("panel"),
           flutter::EncodableValue(front != nullptr &&
                                   front == AppWindows::StashHandle())},
      }));
  return true;
}

void StashChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* text = call.arguments() == nullptr
                         ? nullptr
                         : std::get_if<std::string>(call.arguments());
  if (method == "setHotkey") {
    result->Success(
        flutter::EncodableValue(Register(text == nullptr ? "" : *text)));
    return;
  }
  if (method == "recognizeText") {
    if (text == nullptr || text->empty()) {
      result->Success();
      return;
    }
    // Read in the background; answered on the platform thread.
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared(
        std::move(result));
    const std::wstring path = Utf16FromUtf8(*text);
    const HWND owner = window_;
    std::thread([shared, path, owner]() {
      const std::optional<std::wstring> found = stash_ocr::Recognize(path);
      Post(owner, [shared, found]() {
        if (found) {
          shared->Success(
              flutter::EncodableValue(Utf8FromUtf16(found->c_str())));
        } else {
          shared->Success();
        }
      });
    }).detach();
    return;
  }
  result->NotImplemented();
}
