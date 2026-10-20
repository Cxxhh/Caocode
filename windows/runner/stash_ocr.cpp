#include "stash_ocr.h"

#include <windows.h>
#include <roapi.h>
#include <wincodec.h>
#include <windows.graphics.imaging.h>
#include <windows.graphics.imaging.interop.h>
#include <windows.media.ocr.h>
#include <winstring.h>
#include <wrl/client.h>
#include <wrl/wrappers/corewrappers.h>

#include <algorithm>

namespace stash_ocr {

namespace {

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HString;
using Microsoft::WRL::Wrappers::HStringReference;
using Microsoft::WRL::Wrappers::RoInitializeWrapper;

namespace imaging = ABI::Windows::Graphics::Imaging;
namespace ocr = ABI::Windows::Media::Ocr;

// CLSID_SoftwareBitmapNativeFactory (windows.graphics.imaging.interop.h),
// named here rather than linked for.
constexpr CLSID kSoftwareBitmapFactory = {
    0x84e65691, 0x8602, 0x4a84, {0xbe, 0x46, 0x70, 0x8b, 0xe9, 0xcd, 0x4b, 0x74}};

// How long a picture may take to be read.
constexpr ULONGLONG kTimeoutMilliseconds = 20000;

// |operation|'s results, once it is done (its GetResults says
// E_ILLEGAL_METHOD_CALL until then); E_ABORT if it takes too long.
template <typename Operation, typename Result>
HRESULT Await(Operation* operation, Result* result) {
  const ULONGLONG deadline = ::GetTickCount64() + kTimeoutMilliseconds;
  for (;;) {
    const HRESULT hr = operation->GetResults(result);
    if (hr != E_ILLEGAL_METHOD_CALL) {
      return hr;
    }
    if (::GetTickCount64() > deadline) {
      return E_ABORT;
    }
    ::Sleep(15);
  }
}

// The picture at |path| as the OCR takes it: premultiplied BGRA, no larger
// than |largest| either way.
ComPtr<imaging::ISoftwareBitmap> Load(const std::wstring& path,
                                      UINT32 largest) {
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&factory)))) {
    return nullptr;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(factory->CreateDecoderFromFilename(
          path.c_str(), nullptr, GENERIC_READ,
          WICDecodeMetadataCacheOnDemand, &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame))) {
    return nullptr;
  }
  ComPtr<IWICBitmapSource> source = frame;
  UINT width = 0, height = 0;
  if (FAILED(frame->GetSize(&width, &height)) || width == 0 || height == 0) {
    return nullptr;
  }
  if (largest > 0 && (width > largest || height > largest)) {
    const double scale =
        static_cast<double>(largest) / static_cast<double>((std::max)(width, height));
    const UINT scaled_width =
        (std::max)(1u, static_cast<UINT>(static_cast<double>(width) * scale));
    const UINT scaled_height =
        (std::max)(1u, static_cast<UINT>(static_cast<double>(height) * scale));
    ComPtr<IWICBitmapScaler> scaler;
    if (FAILED(factory->CreateBitmapScaler(&scaler)) ||
        FAILED(scaler->Initialize(source.Get(), scaled_width, scaled_height,
                                  WICBitmapInterpolationModeFant))) {
      return nullptr;
    }
    source = scaler;
  }
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(source.Get(), GUID_WICPixelFormat32bppPBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeMedianCut))) {
    return nullptr;
  }
  ComPtr<IWICBitmap> bitmap;
  if (FAILED(factory->CreateBitmapFromSource(converter.Get(),
                                             WICBitmapCacheOnLoad, &bitmap))) {
    return nullptr;
  }
  ComPtr<ISoftwareBitmapNativeFactory> native;
  if (FAILED(::CoCreateInstance(kSoftwareBitmapFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&native)))) {
    return nullptr;
  }
  ComPtr<imaging::ISoftwareBitmap> software;
  if (FAILED(native->CreateFromWICBitmap(bitmap.Get(), TRUE,
                                         IID_PPV_ARGS(&software)))) {
    return nullptr;
  }
  return software;
}

std::wstring TextOf(const HString& text) {
  UINT32 length = 0;
  const wchar_t* raw = ::WindowsGetStringRawBuffer(text.Get(), &length);
  return raw == nullptr ? std::wstring() : std::wstring(raw, length);
}

}  // namespace

std::optional<std::wstring> Recognize(const std::wstring& path) {
  RoInitializeWrapper apartment(RO_INIT_MULTITHREADED);
  if (FAILED(static_cast<HRESULT>(apartment)) &&
      static_cast<HRESULT>(apartment) != RPC_E_CHANGED_MODE) {
    return std::nullopt;
  }
  ComPtr<ocr::IOcrEngineStatics> statics;
  if (FAILED(::RoGetActivationFactory(
          HStringReference(RuntimeClass_Windows_Media_Ocr_OcrEngine).Get(),
          IID_PPV_ARGS(&statics)))) {
    return std::nullopt;
  }
  // None when the user has no language the system reads.
  ComPtr<ocr::IOcrEngine> engine;
  if (FAILED(statics->TryCreateFromUserProfileLanguages(&engine)) ||
      engine == nullptr) {
    return std::nullopt;
  }
  UINT32 largest = 0;
  statics->get_MaxImageDimension(&largest);
  ComPtr<imaging::ISoftwareBitmap> bitmap = Load(path, largest);
  if (bitmap == nullptr) {
    return std::nullopt;
  }
  ComPtr<ABI::Windows::Foundation::IAsyncOperation<ocr::OcrResult*>> operation;
  ComPtr<ocr::IOcrResult> result;
  if (FAILED(engine->RecognizeAsync(bitmap.Get(), &operation)) ||
      FAILED(Await(operation.Get(), result.GetAddressOf())) ||
      result == nullptr) {
    return std::nullopt;
  }
  ComPtr<ABI::Windows::Foundation::Collections::IVectorView<ocr::OcrLine*>>
      lines;
  UINT32 count = 0;
  if (FAILED(result->get_Lines(&lines)) || FAILED(lines->get_Size(&count))) {
    return std::nullopt;
  }
  std::wstring text;
  for (UINT32 i = 0; i < count; ++i) {
    ComPtr<ocr::IOcrLine> line;
    HString line_text;
    if (FAILED(lines->GetAt(i, &line)) ||
        FAILED(line->get_Text(line_text.GetAddressOf()))) {
      continue;
    }
    if (!text.empty()) {
      text += L'\n';
    }
    text += TextOf(line_text);
  }
  if (text.find_first_not_of(L" \t\r\n") == std::wstring::npos) {
    return std::nullopt;
  }
  return text;
}

}  // namespace stash_ocr
