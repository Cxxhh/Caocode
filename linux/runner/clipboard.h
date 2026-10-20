#ifndef RUNNER_CLIPBOARD_H_
#define RUNNER_CLIPBOARD_H_

#include <flutter_linux/flutter_linux.h>

// Wayland only hands over the clipboard during the paste itself (Ctrl+V,
// Shift+Insert, or the menu's Paste). Snapshot it there; later reads from
// Dart, which are asynchronous, would otherwise come back empty.

// Reads the clipboard now. Call from the key-press or menu activation.
void clipboard_snapshot(void);

// Owned FlValues for the snapshot when it is still the one just taken, and
// a live read otherwise (X11). Null text means there is none. The lists are
// never null. An image file is a map, or null when it is not an image.
FlValue* clipboard_text_value(void);
FlValue* clipboard_files_value(void);
FlValue* clipboard_images_value(void);
FlValue* clipboard_image_file_value(const char* path);

#endif  // RUNNER_CLIPBOARD_H_
