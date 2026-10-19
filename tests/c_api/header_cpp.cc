#include "uWebZockets.h"

#include <type_traits>

static_assert(UWZ_VERSION_MAJOR == 1);
static_assert(UWZ_VERSION_MINOR == 9);
static_assert(UWZ_VERSION_PATCH == 0);
static_assert(UWZ_HTTP_ANY == 7);
static_assert(UWZ_HTTP_QUERY == 8);
static_assert(std::is_standard_layout_v<uwz_slice>);
static_assert(std::is_trivially_copyable_v<uwz_async_response>);
static_assert(std::is_same_v<decltype(&uwz_app_create_tls_ephemeral), uwz_error (*)(uwz_app **)>);
static_assert(std::is_same_v<decltype(&uwz_app_create_http3_ephemeral), uwz_error (*)(uwz_app **)>);

void validate_uwebzockets_header()
{
    uwz_app *app = nullptr;
    (void) app;
}
