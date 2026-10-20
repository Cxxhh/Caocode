#include "login_window.h"

#include <flutter/standard_method_codec.h>
#include <wrl/event.h>

#include <optional>
#include <utility>

#include "utils.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

constexpr wchar_t kWindowClass[] = L"CAOCODE_LOGIN_WINDOW";

// Its size at 100%, as the macOS app's.
constexpr int kWidth = 480;
constexpr int kHeight = 680;
constexpr int kMinWidth = 360;
constexpr int kMinHeight = 480;

std::wstring StringArgument(const flutter::EncodableMap* arguments,
                            const char* key) {
  if (arguments == nullptr) return std::wstring();
  auto found = arguments->find(flutter::EncodableValue(key));
  if (found == arguments->end()) return std::wstring();
  if (const auto* text = std::get_if<std::string>(&found->second)) {
    return Utf16FromUtf8(*text);
  }
  return std::wstring();
}

// The string a JSON string literal is (ExecuteScript's result is the
// script's value as JSON); none for anything else (null).
std::optional<std::wstring> DecodeJsonString(const wchar_t* json) {
  if (json == nullptr || *json != L'"') return std::nullopt;
  std::wstring text;
  for (const wchar_t* at = json + 1; *at != L'\0'; ++at) {
    if (*at == L'"') return text;
    if (*at != L'\\') {
      text.push_back(*at);
      continue;
    }
    ++at;
    switch (*at) {
      case L'"': text.push_back(L'"'); break;
      case L'\\': text.push_back(L'\\'); break;
      case L'/': text.push_back(L'/'); break;
      case L'b': text.push_back(L'\b'); break;
      case L'f': text.push_back(L'\f'); break;
      case L'n': text.push_back(L'\n'); break;
      case L'r': text.push_back(L'\r'); break;
      case L't': text.push_back(L'\t'); break;
      case L'u': {
        unsigned int unit = 0;
        for (int i = 0; i < 4; ++i) {
          const wchar_t digit = *++at;
          unit <<= 4;
          if (digit >= L'0' && digit <= L'9') {
            unit |= static_cast<unsigned int>(digit - L'0');
          } else if (digit >= L'a' && digit <= L'f') {
            unit |= static_cast<unsigned int>(digit - L'a' + 10);
          } else if (digit >= L'A' && digit <= L'F') {
            unit |= static_cast<unsigned int>(digit - L'A' + 10);
          } else {
            return std::nullopt;
          }
        }
        // UTF-16 as JSON has it: surrogates stay pairs.
        text.push_back(static_cast<wchar_t>(unit));
        break;
      }
      default:
        return std::nullopt;
    }
  }
  return std::nullopt;
}

std::wstring TemporaryFolder() {
  wchar_t path[MAX_PATH + 1];
  const DWORD length = ::GetTempPathW(MAX_PATH + 1, path);
  std::wstring folder(path, length);
  return folder + L"Caocode-Login";
}

}  // namespace

LoginWindow::LoginWindow(flutter::BinaryMessenger* messenger, HWND owner)
    : owner_(owner) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "caocode/login_window",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

LoginWindow::~LoginWindow() {
  *alive_ = false;
  channel_->SetMethodCallHandler(nullptr);
  if (window_ != nullptr) {
    ::SetWindowLongPtr(window_, GWLP_USERDATA, 0);
    if (controller_ != nullptr) controller_->Close();
    ::DestroyWindow(window_);
  }
}

void LoginWindow::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> unique) {
  Result result(std::move(unique));
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string& method = call.method_name();
  if (method == "open") {
    const std::wstring url = StringArgument(arguments, "url");
    if (url.rfind(L"https://", 0) != 0 && url.rfind(L"http://", 0) != 0) {
      result->Error("url", "Not a web address");
      return;
    }
    Open(url, StringArgument(arguments, "title"), result);
  } else if (method == "evaluate") {
    Evaluate(StringArgument(arguments, "script"), result);
  } else if (method == "cookies") {
    Cookies(StringArgument(arguments, "url"), result);
  } else if (method == "close") {
    Close();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void LoginWindow::Open(const std::wstring& url, const std::wstring& title,
                       Result result) {
  // One at a time: a new one in place of the one before, which is not said
  // to have closed (this one is open).
  if (HWND before = window_) {
    window_ = nullptr;
    ++generation_;
    if (controller_ != nullptr) controller_->Close();
    controller_ = nullptr;
    web_view_ = nullptr;
    ::DestroyWindow(before);
  }
  static bool registered = false;
  if (!registered) {
    WNDCLASSEXW window_class{};
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = ::GetModuleHandle(nullptr);
    window_class.hCursor = ::LoadCursor(nullptr, IDC_ARROW);
    window_class.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    window_class.lpszClassName = kWindowClass;
    window_class.hIcon = reinterpret_cast<HICON>(::GetClassLongPtr(owner_, GCLP_HICON));
    ::RegisterClassExW(&window_class);
    registered = true;
  }
  // Over the app's window, as big as the macOS app's at its scale.
  const UINT dpi = ::GetDpiForWindow(owner_);
  const int width = ::MulDiv(kWidth, dpi, 96);
  const int height = ::MulDiv(kHeight, dpi, 96);
  RECT frame{};
  ::GetWindowRect(owner_, &frame);
  const int x = frame.left + (frame.right - frame.left - width) / 2;
  const int y = frame.top + (frame.bottom - frame.top - height) / 2;
  window_ = ::CreateWindowExW(0, kWindowClass, title.c_str(),
                              WS_OVERLAPPEDWINDOW, x, y, width, height, owner_,
                              nullptr, ::GetModuleHandle(nullptr), nullptr);
  if (window_ == nullptr) {
    result->Error("window", "The window could not be made");
    return;
  }
  ::SetWindowLongPtr(window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  ::ShowWindow(window_, SW_SHOWNORMAL);
  ::SetForegroundWindow(window_);

  if (environment_ != nullptr) {
    CreateController(url, result);
    return;
  }
  const int generation = generation_;
  std::weak_ptr<bool> alive = alive_;
  const HRESULT started = ::CreateCoreWebView2EnvironmentWithOptions(
      nullptr, TemporaryFolder().c_str(), nullptr,
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [this, alive, generation, url, result](
              HRESULT error, ICoreWebView2Environment* environment) -> HRESULT {
            if (alive.expired()) return S_OK;
            if (FAILED(error) || environment == nullptr) {
              result->Error("webview2", "The WebView2 runtime is not installed");
              Close();
              return S_OK;
            }
            environment_ = environment;
            if (generation != generation_) {
              result->Error("closed", "The window was closed");
              return S_OK;
            }
            CreateController(url, result);
            return S_OK;
          })
          .Get());
  if (FAILED(started)) {
    result->Error("webview2", "The WebView2 runtime is not installed");
    Close();
  }
}

void LoginWindow::CreateController(const std::wstring& url, Result result) {
  const int generation = generation_;
  std::weak_ptr<bool> alive = alive_;
  auto created = Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
      [this, alive, generation, url, result](
          HRESULT error, ICoreWebView2Controller* controller) -> HRESULT {
        if (alive.expired()) return S_OK;
        if (generation != generation_ || window_ == nullptr) {
          if (controller != nullptr) controller->Close();
          result->Error("closed", "The window was closed");
          return S_OK;
        }
        if (FAILED(error) || controller == nullptr) {
          result->Error("webview2", "The web view could not be made");
          Close();
          return S_OK;
        }
        controller_ = controller;
        controller_->get_CoreWebView2(&web_view_);
        Resize();
        // A page's window.open (a sign-in with another site's account,
        // say): in the same view, the window being the user's only one.
        EventRegistrationToken token;
        web_view_->add_NewWindowRequested(
            Callback<ICoreWebView2NewWindowRequestedEventHandler>(
                [this](ICoreWebView2*,
                       ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
                  LPWSTR uri = nullptr;
                  args->put_Handled(TRUE);
                  if (SUCCEEDED(args->get_Uri(&uri)) && uri != nullptr) {
                    if (web_view_ != nullptr) web_view_->Navigate(uri);
                    ::CoTaskMemFree(uri);
                  }
                  return S_OK;
                })
                .Get(),
            &token);
        web_view_->Navigate(url.c_str());
        controller_->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
        result->Success();
        return S_OK;
      });
  // InPrivate where the runtime can (1.0.1185 on): nothing kept.
  ComPtr<ICoreWebView2Environment10> environment10;
  ComPtr<ICoreWebView2ControllerOptions> options;
  if (SUCCEEDED(environment_.As(&environment10)) &&
      SUCCEEDED(environment10->CreateCoreWebView2ControllerOptions(&options))) {
    options->put_IsInPrivateModeEnabled(TRUE);
    environment10->CreateCoreWebView2ControllerWithOptions(window_, options.Get(),
                                                           created.Get());
  } else {
    environment_->CreateCoreWebView2Controller(window_, created.Get());
  }
}

void LoginWindow::Evaluate(const std::wstring& script, Result result) {
  if (web_view_ == nullptr) {
    result->Success();
    return;
  }
  std::weak_ptr<bool> alive = alive_;
  const HRESULT started = web_view_->ExecuteScript(
      script.c_str(),
      Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
          [alive, result](HRESULT error, LPCWSTR json) -> HRESULT {
            if (alive.expired()) return S_OK;
            std::optional<std::wstring> value;
            if (SUCCEEDED(error)) value = DecodeJsonString(json);
            if (value) {
              result->Success(flutter::EncodableValue(Utf8FromUtf16(value->c_str())));
            } else {
              result->Success();
            }
            return S_OK;
          })
          .Get());
  if (FAILED(started)) result->Success();
}

void LoginWindow::Cookies(const std::wstring& url, Result result) {
  ComPtr<ICoreWebView2_2> web_view;
  ComPtr<ICoreWebView2CookieManager> manager;
  if (web_view_ == nullptr || FAILED(web_view_.As(&web_view)) ||
      FAILED(web_view->get_CookieManager(&manager))) {
    result->Success(flutter::EncodableValue(flutter::EncodableMap()));
    return;
  }
  std::weak_ptr<bool> alive = alive_;
  const HRESULT started = manager->GetCookies(
      url.c_str(),
      Callback<ICoreWebView2GetCookiesCompletedHandler>(
          [alive, result](HRESULT error, ICoreWebView2CookieList* list) -> HRESULT {
            if (alive.expired()) return S_OK;
            flutter::EncodableMap cookies;
            UINT32 count = 0;
            if (SUCCEEDED(error) && list != nullptr &&
                SUCCEEDED(list->get_Count(&count))) {
              for (UINT32 i = 0; i < count; ++i) {
                ComPtr<ICoreWebView2Cookie> cookie;
                if (FAILED(list->GetValueAtIndex(i, &cookie))) continue;
                LPWSTR name = nullptr;
                LPWSTR value = nullptr;
                if (SUCCEEDED(cookie->get_Name(&name)) &&
                    SUCCEEDED(cookie->get_Value(&value)) && name != nullptr &&
                    value != nullptr) {
                  cookies[flutter::EncodableValue(Utf8FromUtf16(name))] =
                      flutter::EncodableValue(Utf8FromUtf16(value));
                }
                if (name != nullptr) ::CoTaskMemFree(name);
                if (value != nullptr) ::CoTaskMemFree(value);
              }
            }
            result->Success(flutter::EncodableValue(cookies));
            return S_OK;
          })
          .Get());
  if (FAILED(started)) {
    result->Success(flutter::EncodableValue(flutter::EncodableMap()));
  }
}

void LoginWindow::Close() {
  if (window_ != nullptr) ::DestroyWindow(window_);
}

void LoginWindow::Closed() {
  ++generation_;
  if (controller_ != nullptr) controller_->Close();
  controller_ = nullptr;
  web_view_ = nullptr;
  window_ = nullptr;
  channel_->InvokeMethod("closed", nullptr);
  if (owner_ != nullptr) ::SetForegroundWindow(owner_);
}

void LoginWindow::Resize() {
  if (controller_ == nullptr || window_ == nullptr) return;
  RECT bounds{};
  ::GetClientRect(window_, &bounds);
  controller_->put_Bounds(bounds);
}

LRESULT CALLBACK LoginWindow::WindowProc(HWND window, UINT message,
                                         WPARAM wparam, LPARAM lparam) {
  auto* self =
      reinterpret_cast<LoginWindow*>(::GetWindowLongPtr(window, GWLP_USERDATA));
  if (self != nullptr) {
    switch (message) {
      case WM_SIZE:
        self->Resize();
        return 0;
      case WM_GETMINMAXINFO: {
        const UINT dpi = ::GetDpiForWindow(window);
        auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
        info->ptMinTrackSize.x = ::MulDiv(kMinWidth, dpi, 96);
        info->ptMinTrackSize.y = ::MulDiv(kMinHeight, dpi, 96);
        return 0;
      }
      case WM_DPICHANGED: {
        const auto* suggested = reinterpret_cast<const RECT*>(lparam);
        ::SetWindowPos(window, nullptr, suggested->left, suggested->top,
                       suggested->right - suggested->left,
                       suggested->bottom - suggested->top,
                       SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
      }
      case WM_DESTROY:
        ::SetWindowLongPtr(window, GWLP_USERDATA, 0);
        if (self->window_ == window) self->Closed();
        return 0;
    }
  }
  return ::DefWindowProc(window, message, wparam, lparam);
}
