// Google sign-in for YouTube Music on Linux, in a WebKitGTK window.
//
// flutter_inappwebview's Linux backend needs WPE WebKit, which desktop distros
// rarely ship, so the app runs this small helper instead. It opens Google's own
// sign-in page; once the login lands on music.youtube.com it prints the session
// as one JSON line on stdout and exits 0:
//
//   {"cookies":"...","visitorData":"...","authUser":"0"}
//
// Closing the window exits 3; any other non-zero exit is a failure. The WebKit profile is ephemeral: nothing stays
// on disk here, the app keeps the session itself.

#include <gtk/gtk.h>
#include <libsoup/soup.h>
#include <webkit2/webkit2.h>

#include <cstdio>
#include <cstdlib>
#include <string>

namespace {

// Google refuses sign-in from user agents it reads as embedded web views.
constexpr char kUserAgent[] =
    "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0";
constexpr char kStartUrl[] =
    "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmusic.youtube.com%2F";
constexpr char kOrigin[] = "https://music.youtube.com";
constexpr char kSessionJs[] =
    "(() => { const c = (window.yt && window.yt.config_) || null;"
    " if (!c) return ''; return (c.VISITOR_DATA || '') + '|' + (c.SESSION_INDEX ?? 0); })()";

struct State {
  WebKitWebView* view = nullptr;
  bool checking = false;
  bool done = false;
  bool closed = false;
  int attempts = 0;
};

std::string JsonEscape(const std::string& in) {
  std::string out;
  for (char ch : in) {
    switch (ch) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (static_cast<unsigned char>(ch) < 0x20) {
          char buf[8];
          snprintf(buf, sizeof buf, "\\u%04x", ch);
          out += buf;
        } else {
          out += ch;
        }
    }
  }
  return out;
}

void Check(State* state);

gboolean RetryLater(gpointer data) {
  Check(static_cast<State*>(data));
  return G_SOURCE_REMOVE;
}

// Cookies can settle a moment after the page does: retry for a few seconds.
void NotYet(State* state) {
  state->checking = false;
  if (++state->attempts < 15) g_timeout_add(400, RetryLater, state);
}

struct Pending {
  State* state;
  std::string cookies;
};

void OnSessionJs(GObject* source, GAsyncResult* result, gpointer data) {
  auto* pending = static_cast<Pending*>(data);
  State* state = pending->state;
  GError* error = nullptr;
  JSCValue* value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(source), result, &error);
  std::string session;
  if (value != nullptr) {
    if (jsc_value_is_string(value)) {
      gchar* str = jsc_value_to_string(value);
      session = str;
      g_free(str);
    }
    g_object_unref(value);
  }
  g_clear_error(&error);
  const auto bar = session.find('|');
  const std::string visitor = bar == std::string::npos ? "" : session.substr(0, bar);
  const std::string index = bar == std::string::npos ? "0" : session.substr(bar + 1);
  if (visitor.empty()) {
    NotYet(state);
  } else {
    printf("{\"cookies\":\"%s\",\"visitorData\":\"%s\",\"authUser\":\"%s\"}\n", JsonEscape(pending->cookies).c_str(),
           JsonEscape(visitor).c_str(), JsonEscape(index.empty() ? "0" : index).c_str());
    fflush(stdout);
    state->done = true;
    gtk_main_quit();
  }
  delete pending;
}

void OnCookies(GObject* source, GAsyncResult* result, gpointer data) {
  auto* state = static_cast<State*>(data);
  GError* error = nullptr;
  GList* cookies = webkit_cookie_manager_get_cookies_finish(WEBKIT_COOKIE_MANAGER(source), result, &error);
  g_clear_error(&error);
  std::string header;
  bool signed_in = false;
  for (GList* l = cookies; l != nullptr; l = l->next) {
    auto* cookie = static_cast<SoupCookie*>(l->data);
    const std::string name = soup_cookie_get_name(cookie);
    if (name == "SAPISID" || name == "__Secure-3PAPISID" || name == "__Secure-1PAPISID") signed_in = true;
    if (!header.empty()) header += "; ";
    header += name + "=" + soup_cookie_get_value(cookie);
  }
  g_list_free_full(cookies, reinterpret_cast<GDestroyNotify>(soup_cookie_free));
  if (!signed_in) return NotYet(state);
  webkit_web_view_evaluate_javascript(state->view, kSessionJs, -1, nullptr, nullptr, nullptr, OnSessionJs,
                                      new Pending{state, header});
}

void Check(State* state) {
  if (state->checking || state->done) return;
  const gchar* uri = webkit_web_view_get_uri(state->view);
  if (uri == nullptr || !g_str_has_prefix(uri, kOrigin)) return;
  state->checking = true;
  WebKitWebsiteDataManager* data = webkit_web_view_get_website_data_manager(state->view);
  webkit_cookie_manager_get_cookies(webkit_website_data_manager_get_cookie_manager(data), kOrigin, nullptr,
                                    OnCookies, state);
}

void OnLoadChanged(WebKitWebView*, WebKitLoadEvent event, gpointer data) {
  if (event != WEBKIT_LOAD_FINISHED) return;
  auto* state = static_cast<State*>(data);
  state->attempts = 0;
  Check(state);
}

}  // namespace

int main(int argc, char** argv) {
  // WebKitGTK's DMA-BUF renderer kills the process with a Wayland "Error 71
  // (Protocol error)" on NVIDIA and some hybrid-GPU setups. The window is a
  // login form: the plain renderer is plenty, and works everywhere.
  setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 0);
  gtk_init(&argc, &argv);
  State state;

  GtkWidget* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), "Sign in to YouTube Music");
  gtk_window_set_default_size(GTK_WINDOW(window), 480, 720);
  g_signal_connect(window, "delete-event", G_CALLBACK(+[](GtkWidget*, GdkEvent*, gpointer data) -> gboolean {
                     static_cast<State*>(data)->closed = true;
                     return FALSE;
                   }),
                   &state);
  g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), nullptr);

  WebKitWebsiteDataManager* data = webkit_website_data_manager_new_ephemeral();
  WebKitWebContext* context = webkit_web_context_new_with_website_data_manager(data);
  state.view = WEBKIT_WEB_VIEW(webkit_web_view_new_with_context(context));
  webkit_settings_set_user_agent(webkit_web_view_get_settings(state.view), kUserAgent);
  g_signal_connect(state.view, "load-changed", G_CALLBACK(OnLoadChanged), &state);

  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(state.view));
  webkit_web_view_load_uri(state.view, kStartUrl);
  gtk_widget_show_all(window);
  gtk_main();
  return state.done ? 0 : state.closed ? 3 : 1;
}
