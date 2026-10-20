#include "clipboard.h"

#include <gtk/gtk.h>

#include <string.h>

// How long a snapshot still answers a paste that was started by the key or
// the menu. The editor asks for files, then text, then images, one after
// another, all from that one gesture.
static const gint64 kSnapshotTtl = 2 * G_USEC_PER_SEC;

typedef struct {
  gint64 at;
  gchar* text;
  GSList* files;
  guint8* png;
  gsize png_len;
} Snapshot;

static Snapshot snap = {};

static void snapshot_clear(void) {
  g_clear_pointer(&snap.text, g_free);
  g_slist_free_full(snap.files, g_free);
  snap.files = nullptr;
  g_free(snap.png);
  snap.png = nullptr;
  snap.png_len = 0;
  snap.at = 0;
}

static gboolean meaningful(const gchar* text) {
  if (text == nullptr) return FALSE;
  for (const gchar* p = text; *p != '\0'; p++) {
    if (*p != ' ' && *p != '\n' && *p != '\r' && *p != '\t') return TRUE;
  }
  return FALSE;
}

static gchar* payload_text(GtkClipboard* clipboard, const gchar* mime) {
  GtkSelectionData* data = gtk_clipboard_wait_for_contents(
      clipboard, gdk_atom_intern_static_string(mime));
  if (data == nullptr) return nullptr;
  const guchar* bytes = gtk_selection_data_get_data(data);
  const gint length = gtk_selection_data_get_length(data);
  gchar* text = nullptr;
  if (bytes != nullptr && length > 0) {
    text = g_strndup((const gchar*)bytes, (gsize)length);
  }
  gtk_selection_data_free(data);
  return text;
}

// file:// URIs, one per line. GNOME's list starts with "copy" or "cut".
static GSList* paths_from_uris(const gchar* raw, gboolean gnome) {
  if (raw == nullptr) return nullptr;
  gchar** lines = g_strsplit(raw, "\n", 0);
  GSList* paths = nullptr;
  for (guint i = 0; lines[i] != nullptr; i++) {
    g_strstrip(lines[i]);
    if (lines[i][0] == '\0') continue;
    if (gnome && i == 0 &&
        (strcmp(lines[i], "copy") == 0 || strcmp(lines[i], "cut") == 0)) {
      continue;
    }
    if (!g_str_has_prefix(lines[i], "file:")) continue;
    gchar* path = g_filename_from_uri(lines[i], nullptr, nullptr);
    if (path != nullptr && g_file_test(path, G_FILE_TEST_EXISTS)) {
      paths = g_slist_append(paths, path);
    } else {
      g_free(path);
    }
  }
  g_strfreev(lines);
  return paths;
}

static guint8* png_from_clipboard(GtkClipboard* clipboard, gsize* length) {
  *length = 0;
  GtkSelectionData* data = gtk_clipboard_wait_for_contents(
      clipboard, gdk_atom_intern_static_string("image/png"));
  if (data != nullptr) {
    const guchar* bytes = gtk_selection_data_get_data(data);
    const gint size = gtk_selection_data_get_length(data);
    if (bytes != nullptr && size > 8) {
      guint8* copy = static_cast<guint8*>(g_malloc((gsize)size));
      memcpy(copy, bytes, (gsize)size);
      *length = (gsize)size;
      gtk_selection_data_free(data);
      return copy;
    }
    gtk_selection_data_free(data);
  }

  GdkPixbuf* pixbuf = gtk_clipboard_wait_for_image(clipboard);
  if (pixbuf == nullptr) return nullptr;
  gchar* buffer = nullptr;
  gsize size = 0;
  GError* error = nullptr;
  const gboolean saved = gdk_pixbuf_save_to_buffer(pixbuf, &buffer, &size,
                                                    "png", &error, nullptr);
  g_object_unref(pixbuf);
  if (!saved) {
    g_clear_error(&error);
    return nullptr;
  }
  *length = size;
  return reinterpret_cast<guint8*>(buffer);
}

void clipboard_snapshot(void) {
  snapshot_clear();
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);

  g_autofree gchar* gnome =
      payload_text(clipboard, "x-special/gnome-copied-files");
  snap.files = paths_from_uris(gnome, TRUE);
  if (snap.files == nullptr) {
    g_autofree gchar* uris = payload_text(clipboard, "text/uri-list");
    snap.files = paths_from_uris(uris, FALSE);
  }

  gchar* text = gtk_clipboard_wait_for_text(clipboard);
  if (!meaningful(text)) {
    g_free(text);
    text = nullptr;
  }
  snap.text = text;

  // Text wins over a picture of it, as on Windows. Copied files are read
  // from disk instead (readImageFile), so the image bytes are not needed.
  if (snap.files == nullptr && snap.text == nullptr) {
    snap.png = png_from_clipboard(clipboard, &snap.png_len);
  }
  snap.at = g_get_monotonic_time();
}

static gboolean fresh(void) {
  return snap.at != 0 &&
         g_get_monotonic_time() - snap.at < kSnapshotTtl;
}

static void ensure(void) {
  if (!fresh()) clipboard_snapshot();
}

FlValue* clipboard_text_value(void) {
  ensure();
  if (snap.text == nullptr) return nullptr;
  return fl_value_new_string(snap.text);
}

FlValue* clipboard_files_value(void) {
  ensure();
  FlValue* list = fl_value_new_list();
  for (GSList* item = snap.files; item != nullptr; item = item->next) {
    const gchar* path = static_cast<const gchar*>(item->data);
    FlValue* map = fl_value_new_map();
    fl_value_set_string_take(map, "path", fl_value_new_string(path));
    fl_value_set_string_take(
        map, "directory",
        fl_value_new_bool(g_file_test(path, G_FILE_TEST_IS_DIR)));
    fl_value_append_take(list, map);
  }
  return list;
}

FlValue* clipboard_images_value(void) {
  ensure();
  FlValue* list = fl_value_new_list();
  if (snap.png != nullptr && snap.png_len > 0) {
    FlValue* map = fl_value_new_map();
    fl_value_set_string_take(
        map, "bytes", fl_value_new_uint8_list(snap.png, snap.png_len));
    fl_value_set_string_take(map, "type", fl_value_new_string("image/png"));
    fl_value_append_take(list, map);
  }
  return list;
}

FlValue* clipboard_image_file_value(const char* path) {
  if (path == nullptr || path[0] == '\0' ||
      !g_file_test(path, G_FILE_TEST_IS_REGULAR)) {
    return nullptr;
  }
  GError* error = nullptr;
  GdkPixbuf* pixbuf = gdk_pixbuf_new_from_file(path, &error);
  if (pixbuf == nullptr) {
    g_clear_error(&error);
    return nullptr;
  }
  gchar* buffer = nullptr;
  gsize size = 0;
  const gboolean saved =
      gdk_pixbuf_save_to_buffer(pixbuf, &buffer, &size, "png", &error, nullptr);
  g_object_unref(pixbuf);
  if (!saved) {
    g_clear_error(&error);
    return nullptr;
  }
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(
      map, "bytes",
      fl_value_new_uint8_list(reinterpret_cast<guint8*>(buffer), size));
  fl_value_set_string_take(map, "type", fl_value_new_string("image/png"));
  g_autofree gchar* name = g_path_get_basename(path);
  fl_value_set_string_take(map, "name", fl_value_new_string(name));
  g_free(buffer);
  return map;
}
