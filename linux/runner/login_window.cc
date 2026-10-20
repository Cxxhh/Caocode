#include "login_window.h"

#include <string.h>

#ifdef HAVE_WEBKIT
#include <webkit2/webkit2.h>
#endif

namespace {

FlMethodChannel* channel = nullptr;
GtkWindow* owner = nullptr;

#ifdef HAVE_WEBKIT
const char* map_string(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(value);
}
#endif

void respond(FlMethodCall* call, FlValue* result) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  fl_method_call_respond(call, response, nullptr);
}

#ifdef HAVE_WEBKIT

GtkWidget* window = nullptr;
WebKitWebView* web_view = nullptr;

// A page's window.open (a sign-in with another site's account, say): in
// the same view, the window being the user's only one here.
GtkWidget* create_cb(WebKitWebView* view, WebKitNavigationAction* action,
                     gpointer) {
  WebKitURIRequest* request = webkit_navigation_action_get_request(action);
  const char* uri = request == nullptr ? nullptr : webkit_uri_request_get_uri(request);
  if (uri != nullptr) webkit_web_view_load_uri(view, uri);
  return nullptr;
}

void destroy_cb(GtkWidget* closing, gpointer) {
  if (closing != window) return;
  window = nullptr;
  web_view = nullptr;
  fl_method_channel_invoke_method(channel, "closed", nullptr, nullptr, nullptr,
                                  nullptr);
}

void open(const char* url, const char* title) {
  // One at a time: a new one in place of the one before, which is not said
  // to have closed (this one is open).
  if (GtkWidget* before = window) {
    window = nullptr;
    web_view = nullptr;
    gtk_widget_destroy(before);
  }
  g_autoptr(WebKitWebContext) context = webkit_web_context_new_ephemeral();
  web_view = WEBKIT_WEB_VIEW(webkit_web_view_new_with_context(context));
  g_signal_connect(web_view, "create", G_CALLBACK(create_cb), nullptr);
  window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), title);
  gtk_window_set_default_size(GTK_WINDOW(window), 480, 680);
  if (owner != nullptr) {
    gtk_window_set_transient_for(GTK_WINDOW(window), owner);
    gtk_window_set_position(GTK_WINDOW(window),
                            GTK_WIN_POS_CENTER_ON_PARENT);
  }
  GdkGeometry minimum = {};
  minimum.min_width = 360;
  minimum.min_height = 480;
  gtk_window_set_geometry_hints(GTK_WINDOW(window), nullptr, &minimum,
                                GDK_HINT_MIN_SIZE);
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(web_view));
  g_signal_connect(window, "destroy", G_CALLBACK(destroy_cb), nullptr);
  webkit_web_view_load_uri(web_view, url);
  gtk_widget_show_all(window);
  gtk_window_present(GTK_WINDOW(window));
}

void evaluated_cb(GObject* source, GAsyncResult* result, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(JSCValue) value = webkit_web_view_evaluate_javascript_finish(
      WEBKIT_WEB_VIEW(source), result, &error);
  if (value == nullptr || !jsc_value_is_string(value)) {
    respond(call, nullptr);
    return;
  }
  g_autofree char* text = jsc_value_to_string(value);
  g_autoptr(FlValue) string = fl_value_new_string(text);
  respond(call, string);
}

void cookies_cb(GObject* source, GAsyncResult* result, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  g_autoptr(GError) error = nullptr;
  GList* cookies = webkit_cookie_manager_get_cookies_finish(
      WEBKIT_COOKIE_MANAGER(source), result, &error);
  g_autoptr(FlValue) found = fl_value_new_map();
  for (GList* item = cookies; item != nullptr; item = item->next) {
    auto* cookie = static_cast<SoupCookie*>(item->data);
    fl_value_set_string_take(found, soup_cookie_get_name(cookie),
                             fl_value_new_string(soup_cookie_get_value(cookie)));
  }
  g_list_free_full(cookies, reinterpret_cast<GDestroyNotify>(soup_cookie_free));
  respond(call, found);
}

#endif  // HAVE_WEBKIT

void method_call_cb(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const char* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
#ifdef HAVE_WEBKIT
  if (strcmp(method, "open") == 0) {
    const char* url = map_string(args, "url");
    if (url == nullptr || (g_ascii_strncasecmp(url, "https://", 8) != 0 &&
                           g_ascii_strncasecmp(url, "http://", 7) != 0)) {
      fl_method_call_respond_error(call, "url", "Not a web address", nullptr,
                                   nullptr);
      return;
    }
    const char* title = map_string(args, "title");
    open(url, title == nullptr ? "" : title);
    respond(call, nullptr);
  } else if (strcmp(method, "evaluate") == 0) {
    const char* script = map_string(args, "script");
    if (web_view == nullptr || script == nullptr) {
      respond(call, nullptr);
      return;
    }
    webkit_web_view_evaluate_javascript(web_view, script, -1, nullptr, nullptr,
                                        nullptr, evaluated_cb,
                                        g_object_ref(call));
  } else if (strcmp(method, "cookies") == 0) {
    const char* url = map_string(args, "url");
    if (web_view == nullptr || url == nullptr) {
      g_autoptr(FlValue) none = fl_value_new_map();
      respond(call, none);
      return;
    }
    WebKitWebsiteDataManager* data =
        webkit_web_view_get_website_data_manager(web_view);
    webkit_cookie_manager_get_cookies(
        webkit_website_data_manager_get_cookie_manager(data), url, nullptr,
        cookies_cb, g_object_ref(call));
  } else if (strcmp(method, "close") == 0) {
    if (window != nullptr) gtk_widget_destroy(window);
    respond(call, nullptr);
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
  }
#else
  if (strcmp(method, "open") == 0) {
    fl_method_call_respond_error(
        call, "webkit", "This build has no web view (WebKitGTK)", nullptr,
        nullptr);
  } else if (strcmp(method, "cookies") == 0) {
    g_autoptr(FlValue) none = fl_value_new_map();
    respond(call, none);
  } else {
    respond(call, nullptr);
  }
  (void)args;
#endif
}

}  // namespace

void login_window_register(FlBinaryMessenger* messenger, GtkWindow* window) {
  owner = window;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_clear_object(&channel);
  channel = fl_method_channel_new(messenger, "caocode/login_window",
                                  FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                            nullptr);
}
