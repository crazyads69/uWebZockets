#include "uWebZockets.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <process.h>
#define close_socket(s) closesocket(s)
#define get_pid() ((unsigned int)_getpid())
#else
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#define close_socket(s) close(s)
#define get_pid() ((unsigned int)getpid())
#endif

#include <stdint.h>
#include <string.h>

struct lifecycle_context {
    uwz_app **app;
    uwz_error response_result;
    uwz_error shutdown_result;
    uwz_error destroy_result;
    bool called;
};

static uwz_slice make_slice(const char *value)
{
    uwz_slice slice;

    slice.data = (const uint8_t *) value;
    slice.length = strlen(value);
    return slice;
}

static void route_handler(
    const uwz_request *request,
    uwz_response *response,
    void *user_data
)
{
    struct lifecycle_context *context = user_data;

    (void) request;
    context->called = true;
    context->response_result = uwz_response_end(
        response,
        make_slice("200 OK"),
        make_slice("ok")
    );
    context->shutdown_result = uwz_app_shutdown(*context->app);
    context->destroy_result = uwz_app_destroy(context->app);
}

static uwz_middleware_result middleware(
    const uwz_request *request,
    uwz_response *response,
    void *user_data
)
{
    (void) request;
    (void) response;
    (void) user_data;
    return UWZ_MIDDLEWARE_CONTINUE;
}

int main(void)
{
    static const char route[] = "/query";
    static const char trace_route[] = "/trace";
    static const char bad_address[] = "not-an-ip-address";
    static const char request[] =
        "QUERY /query HTTP/1.1\r\n"
        "Host: localhost\r\n"
        "Connection: close\r\n"
        "Content-Type: application/octet-stream\r\n"
        "Content-Length: 0\r\n\r\n";
    struct lifecycle_context context;
    struct sockaddr_in address;
    uwz_app *app = NULL;
    uwz_error result;
    uint16_t port = 0;
#ifdef _WIN32
    SOCKET client = INVALID_SOCKET;
    WSADATA wsa_data;
    if (WSAStartup(MAKEWORD(2, 2), &wsa_data) != 0)
        return 100;
#else
    int client = -1;
#endif
    size_t sent = 0;
    unsigned int attempt;

    if (strcmp(uwz_version(), "2.0.5") != 0)
        return 1;
    if (strcmp(uwz_error_name(UWZ_OK), "ok") != 0)
        return 2;
    {
        /* *out_app must be NULL; a non-NULL value is left unchanged. */
        uwz_app *occupied = (uwz_app *) (uintptr_t) 1;
        if (uwz_app_create(&occupied) != UWZ_ERROR_INVALID_ARGUMENT ||
            occupied != (uwz_app *) (uintptr_t) 1)
            return 18;
    }
    if (uwz_app_create(&app) != UWZ_OK || app == NULL)
        return 3;
    context.app = &app;
    context.response_result = UWZ_ERROR_INTERNAL;
    context.shutdown_result = UWZ_ERROR_INTERNAL;
    context.destroy_result = UWZ_ERROR_INTERNAL;
    context.called = false;
    if (uwz_app_route(
            app,
            UWZ_HTTP_QUERY,
            route,
            sizeof(route) - 1,
            route_handler,
            &context
        ) != UWZ_OK)
        return 4;
    if (uwz_app_route(
            app,
            UWZ_HTTP_TRACE,
            trace_route,
            sizeof(trace_route) - 1,
            route_handler,
            &context
        ) != UWZ_OK)
        return 19;
    if (uwz_app_use(app, middleware, NULL) != UWZ_OK)
        return 5;
    if (uwz_app_listen(
            app,
            bad_address,
            sizeof(bad_address) - 1,
            8080
        ) != UWZ_ERROR_INVALID_ARGUMENT)
        return 6;

    for (attempt = 0; attempt < 512; attempt++) {
        port = (uint16_t) (20000U +
            (((unsigned int) get_pid() + attempt) % 30000U));
        result = uwz_app_listen(app, "127.0.0.1", 9, port);
        if (result == UWZ_OK)
            break;
        if (result != UWZ_ERROR_IO)
            return 7;
    }
    if (attempt == 512)
        return 8;

    client = socket(AF_INET, SOCK_STREAM, 0);
#ifdef _WIN32
    if (client == INVALID_SOCKET)
        return 9;
#else
    if (client == -1)
        return 9;
#endif
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(client, (const struct sockaddr *) &address, sizeof(address)) != 0)
        return 10;

    while (sent < sizeof(request) - 1) {
#ifdef _WIN32
        int written = send(
            client,
            request + sent,
            (int) (sizeof(request) - 1 - sent),
            0
        );
        if (written < 0 && WSAGetLastError() == WSAEINTR)
            continue;
        if (written <= 0)
            return 11;
#else
        ssize_t written = write(
            client,
            request + sent,
            sizeof(request) - 1 - sent
        );
        if (written < 0 && errno == EINTR)
            continue;
        if (written <= 0)
            return 11;
#endif
        sent += (size_t) written;
    }

    if (uwz_app_run(app) != UWZ_OK)
        return 12;
    if (!context.called || context.response_result != UWZ_OK)
        return 13;
    if (context.shutdown_result != UWZ_OK)
        return 14;
    if (context.destroy_result != UWZ_ERROR_INVALID_STATE || app == NULL)
        return 15;
    if (close_socket(client) != 0)
        return 16;
#ifdef _WIN32
    WSACleanup();
#endif
    if (uwz_app_destroy(&app) != UWZ_OK || app != NULL)
        return 17;
    return 0;
}
