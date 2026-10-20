#ifndef RUNNER_STASH_CHANNEL_H_
#define RUNNER_STASH_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <windows.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <utility>

// `caocode/stash` (see lib/stash/stash_host.dart; the macOS app answers the
// same in StashPanel.swift): the shortcut that shows the stash's panel from
// any app, a hot key of the system's on the main window, and the text in
// pictures.
//
//   setHotkey spec                takes `ctrl+shift+space`… in place of the
//                                 one it had, none for empty: whether the
//                                 system gave it (another app may hold it)
//   recognizeText path            the text in the picture, or null
//
// and tells Flutter `pressed {self, panel}`: whether one of the app's
// windows was in front, and whether that was the stash's panel.
class StashChannel {
 public:
  // What work done off the platform thread posts the main window, its
  // lparam a std::function<void()>* to run there (see Run).
  static constexpr UINT kRunMessage = WM_APP + 0x46;

  StashChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~StashChannel();

  StashChannel(const StashChannel&) = delete;
  StashChannel& operator=(const StashChannel&) = delete;

  // The window's WM_HOTKEY: handled when it is the stash's.
  bool HandleHotkey(WPARAM id);

  // A kRunMessage's task: run when |alive| (the channel still is), dropped
  // otherwise.
  static void Run(LPARAM task, bool alive);

  // |spec|'s modifiers (MOD_…) and virtual key; nullopt when it names no
  // key, or no modifier (a key alone would be taken from every app).
  static std::optional<std::pair<UINT, UINT>> Parse(const std::string& spec);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool Register(const std::string& spec);
  void Unregister();

  // Runs |task| on the platform thread, from any other.
  static void Post(HWND window, std::function<void()> task);

  HWND window_;
  bool registered_ = false;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_STASH_CHANNEL_H_
