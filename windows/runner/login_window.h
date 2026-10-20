#ifndef RUNNER_LOGIN_WINDOW_H_
#define RUNNER_LOGIN_WINDOW_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <windows.h>
#include <wrl/client.h>

#include <memory>
#include <string>

#include "WebView2.h"

// The channel build's login window (lib/channel/account/; the macOS app
// answers the same in LoginWindow.swift), over `caocode/login_window`: the
// user's channel's account site in a WebView2 of its own, InPrivate (its
// cookies and storage gone once it closes).
//
//   open (url, title)   opens it, in place of one open; done once the page
//                       is on its way, an error without the WebView2 runtime
//   evaluate (script)   the string the script comes to, or null
//   cookies (url)       the cookies it has for the url, HttpOnly ones too
//   close               closes it
//
// and tells Flutter `closed` once it has, however it did.
class LoginWindow {
 public:
  LoginWindow(flutter::BinaryMessenger* messenger, HWND owner);
  ~LoginWindow();

  LoginWindow(const LoginWindow&) = delete;
  LoginWindow& operator=(const LoginWindow&) = delete;

 private:
  using Result = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void Open(const std::wstring& url, const std::wstring& title, Result result);
  void CreateController(const std::wstring& url, Result result);
  void Evaluate(const std::wstring& script, Result result);
  void Cookies(const std::wstring& url, Result result);
  void Close();

  // The window has gone: the web view with it, and Flutter told.
  void Closed();
  void Resize();

  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND owner_;
  HWND window_ = nullptr;

  // Each window's: what was asked for one closed since comes to nothing.
  int generation_ = 0;

  // Made once, the first time; its folder in the temporary one (InPrivate
  // keeps nothing there that outlasts a window).
  Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment_;
  Microsoft::WRL::ComPtr<ICoreWebView2Controller> controller_;
  Microsoft::WRL::ComPtr<ICoreWebView2> web_view_;

  // Gone with this: the web view's callbacks after that do nothing.
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
};

#endif  // RUNNER_LOGIN_WINDOW_H_
