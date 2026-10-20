#ifndef RUNNER_STASH_OCR_H_
#define RUNNER_STASH_OCR_H_

#include <optional>
#include <string>

namespace stash_ocr {

// The text in the picture at |path|, read by the system's OCR
// (Windows.Media.Ocr, in the user's languages), its lines one to a line;
// nullopt when there is none or it cannot be read. Blocks: called off the
// platform thread, on one that may take COM (it starts the apartment it
// needs).
std::optional<std::wstring> Recognize(const std::wstring& path);

}  // namespace stash_ocr

#endif  // RUNNER_STASH_OCR_H_
