#ifndef UWEBZOCKETS_H
#define UWEBZOCKETS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UWZ_VERSION_MAJOR 2
#define UWZ_VERSION_MINOR 0
#define UWZ_VERSION_PATCH 0

/* Versioned fixed capacities of the C ABI. */
#define UWZ_MAX_ROUTES 64
#define UWZ_MAX_MIDDLEWARE 32
/* Inline captures always available; the count may exceed this when the
   application raises ServerConfig.max_route_params. */
#define UWZ_MAX_ROUTE_PARAMETERS 16
#define UWZ_MAX_ROUTE_PATH_LENGTH 2048

typedef struct uwz_app uwz_app;
typedef struct uwz_request uwz_request;
typedef struct uwz_response uwz_response;
typedef struct uwz_websocket uwz_websocket;
typedef struct uwz_async_response uwz_async_response;

/*
 * This header exposes the high-level fixed-capacity server ABI. Compile-time
 * Zig configuration and low-level protocol-helper modules have no C entry
 * points in ABI version 1.0.
 */

typedef struct uwz_slice {
    const uint8_t *data;
    size_t length;
} uwz_slice;

/*
 * A zero-length slice may use NULL data. Every non-empty slice passed into the
 * API is borrowed only for that call unless a registration function explicitly
 * states that it copies the bytes.
 */

/*
 * Copyable one-shot token for deferred response completion.
 *
 * Treat both fields as private. The pointer supplied to an async callback is
 * callback-local. A callback returning UWZ_HANDLER_PENDING must copy the whole
 * struct into caller-owned storage. The copy remains usable on the owning event
 * loop until completion or app shutdown. It must never be used after app
 * destruction. Generation checks reject stale and duplicate completion.
 */
struct uwz_async_response {
    void *state;
    uint64_t generation;
};

typedef enum uwz_error {
    UWZ_OK = 0,
    UWZ_ERROR_INVALID_ARGUMENT = -1,
    UWZ_ERROR_OUT_OF_MEMORY = -2,
    UWZ_ERROR_INVALID_STATE = -3,
    UWZ_ERROR_ALREADY_EXISTS = -4,
    UWZ_ERROR_CAPACITY = -5,
    UWZ_ERROR_WOULD_BLOCK = -6,
    UWZ_ERROR_PROTOCOL = -7,
    UWZ_ERROR_IO = -8,
    UWZ_ERROR_UNSUPPORTED = -9,
    UWZ_ERROR_INTERNAL = -10
} uwz_error;

typedef enum uwz_http_method {
    UWZ_HTTP_GET = 0,
    UWZ_HTTP_HEAD = 1,
    UWZ_HTTP_POST = 2,
    UWZ_HTTP_PUT = 3,
    UWZ_HTTP_DELETE = 4,
    UWZ_HTTP_PATCH = 5,
    UWZ_HTTP_OPTIONS = 6,
    UWZ_HTTP_ANY = 7,
    UWZ_HTTP_QUERY = 8,
    UWZ_HTTP_TRACE = 9
} uwz_http_method;

typedef enum uwz_handler_result {
    /* The callback completed the token before returning. */
    UWZ_HANDLER_COMPLETE = 0,
    /* The callback copied the token and will complete it later. */
    UWZ_HANDLER_PENDING = 1
} uwz_handler_result;

typedef enum uwz_middleware_result {
    UWZ_MIDDLEWARE_CONTINUE = 0,
    UWZ_MIDDLEWARE_COMPLETE = 1,
    /* Reserved: middleware is synchronous and this value fails closed. */
    UWZ_MIDDLEWARE_PENDING = 2
} uwz_middleware_result;

typedef enum uwz_ws_opcode {
    UWZ_WS_TEXT = 0x1,
    UWZ_WS_BINARY = 0x2,
    UWZ_WS_CLOSE = 0x8,
    UWZ_WS_PING = 0x9,
    UWZ_WS_PONG = 0xa
} uwz_ws_opcode;

typedef enum uwz_ws_compression {
    UWZ_WS_COMPRESSION_DISABLED = 0,
    UWZ_WS_COMPRESSION_PERMESSAGE_DEFLATE = 1
} uwz_ws_compression;

typedef void (*uwz_http_handler)(
    const uwz_request *request,
    uwz_response *response,
    void *user_data
);

/*
 * Deferred route callback. request and response point to callback-local views.
 * Copy *response before returning UWZ_HANDLER_PENDING. Request fields and route
 * parameters must be copied separately if needed after the callback returns.
 */
typedef uwz_handler_result (*uwz_async_handler)(
    const uwz_request *request,
    uwz_async_response *response,
    void *user_data
);

/*
 * Ordered synchronous middleware callback. It may end response before returning
 * UWZ_MIDDLEWARE_COMPLETE. All pointers are borrowed for this invocation only.
 */
typedef uwz_middleware_result (*uwz_middleware)(
    const uwz_request *request,
    uwz_response *response,
    void *user_data
);

typedef bool (*uwz_ws_upgrade_handler)(
    const uwz_request *request,
    void *user_data
);

typedef void (*uwz_ws_open_handler)(uwz_websocket *socket, void *user_data);

typedef void (*uwz_ws_message_handler)(
    uwz_websocket *socket,
    uwz_slice message,
    uwz_ws_opcode opcode,
    void *user_data
);

typedef void (*uwz_ws_event_handler)(uwz_websocket *socket, void *user_data);

/*
 * Frozen for ABI version 1.x: field order, field types, and size must not
 * change. New behavior knobs are exposed through new entry points rather than
 * added fields, so a caller compiled against an older header stays safe.
 */
typedef struct uwz_ws_behavior {
    uwz_ws_upgrade_handler upgrade;
    uwz_ws_open_handler open;
    uwz_ws_message_handler message;
    uwz_ws_event_handler drain;
    uwz_ws_event_handler close;
    void *user_data;
    uwz_ws_compression compression;
    uint64_t max_frame_size;
    uint64_t max_message_size;
} uwz_ws_behavior;

const char *uwz_version(void);
const char *uwz_error_name(uwz_error code);

/*
 * Application creation. Every entry point requires *out_app to be NULL before
 * the call; a non-NULL value is rejected with UWZ_ERROR_INVALID_ARGUMENT so a
 * live handle is never overwritten.
 */
uwz_error uwz_app_create(uwz_app **out_app);
uwz_error uwz_app_create_tls(
    const char *certificate_path,
    const char *private_key_path,
    uwz_app **out_app
);
uwz_error uwz_app_create_http3(
    const char *certificate_path,
    const char *private_key_path,
    uwz_app **out_app
);
/*
 * Creates a TLS application with an in-memory self-signed localhost
 * certificate for local development. No files are read from disk; do not
 * use generated certificates in production.
 */
uwz_error uwz_app_create_tls_ephemeral(uwz_app **out_app);
/*
 * Creates a dual HTTP/1.1 and HTTP/3 application with in-memory self-signed
 * localhost certificates for local development.
 */
uwz_error uwz_app_create_http3_ephemeral(uwz_app **out_app);
/*
 * Stops listeners, drains completions, and invalidates outstanding async
 * tokens. From a callback this requests shutdown without re-entering the event
 * loop; the active uwz_app_run call drains completions before it returns.
 */
uwz_error uwz_app_shutdown(uwz_app *app);
/*
 * Shuts down, releases the app, and writes NULL through app on success. Calling
 * this from an application callback returns UWZ_ERROR_INVALID_STATE and leaves
 * the handle unchanged; destroy it after uwz_app_run returns.
 */
uwz_error uwz_app_destroy(uwz_app **app);

/*
 * Registers a route. path is copied; user_data remains caller-owned and must
 * remain valid until shutdown has drained callbacks.
 */
uwz_error uwz_app_route(
    uwz_app *app,
    uwz_http_method method,
    const char *path,
    size_t path_length,
    uwz_http_handler handler,
    void *user_data
);
/* Registers a deferred route with the same copied-path/context lifetime rules. */
uwz_error uwz_app_route_async(
    uwz_app *app,
    uwz_http_method method,
    const char *path,
    size_t path_length,
    uwz_async_handler handler,
    void *user_data
);
/* Appends middleware in registration order, up to UWZ_MAX_MIDDLEWARE entries. */
uwz_error uwz_app_use(
    uwz_app *app,
    uwz_middleware middleware,
    void *user_data
);
uwz_error uwz_app_ws(
    uwz_app *app,
    const char *path,
    size_t path_length,
    const uwz_ws_behavior *behavior
);

uwz_error uwz_app_listen(
    uwz_app *app,
    const char *address,
    size_t address_length,
    uint16_t port
);
uwz_error uwz_app_listen_udp(
    uwz_app *app,
    const char *address,
    size_t address_length,
    uint16_t port
);
uwz_error uwz_app_run(uwz_app *app);
size_t uwz_app_publish(
    uwz_app *app,
    uwz_slice topic,
    uwz_slice message,
    bool is_text
);

uwz_slice uwz_request_method(const uwz_request *request);
uwz_slice uwz_request_target(const uwz_request *request);
uwz_slice uwz_request_path(const uwz_request *request);
uwz_slice uwz_request_query(const uwz_request *request);
uwz_slice uwz_request_body(const uwz_request *request);
uwz_slice uwz_request_header(const uwz_request *request, uwz_slice name);
size_t uwz_request_header_count(const uwz_request *request, uwz_slice name);
/* Returns a case-sensitive :name or terminal *name capture borrowed from request. */
uwz_slice uwz_request_parameter(const uwz_request *request, uwz_slice name);
/* Returns the total route-capture count for this request. */
size_t uwz_request_parameter_count(const uwz_request *request);

uwz_error uwz_response_end(
    uwz_response *response,
    uwz_slice status,
    uwz_slice body
);
uwz_error uwz_response_end_with_headers(
    uwz_response *response,
    uwz_slice status,
    uwz_slice headers,
    uwz_slice body
);
uwz_error uwz_response_begin_chunked(
    uwz_response *response,
    uwz_slice status,
    uwz_slice headers
);
uwz_error uwz_response_write_chunk(uwz_response *response, uwz_slice chunk);
uwz_error uwz_response_end_chunks(uwz_response *response);

/*
 * Completes a copied token exactly once on its owning event-loop thread.
 * status, headers, and body are borrowed only for this call. Stale or duplicate
 * tokens return UWZ_ERROR_INVALID_STATE.
 */
uwz_error uwz_async_response_end(
    uwz_async_response *response,
    uwz_slice status,
    uwz_slice body
);
uwz_error uwz_async_response_end_with_headers(
    uwz_async_response *response,
    uwz_slice status,
    uwz_slice headers,
    uwz_slice body
);

uwz_error uwz_websocket_send(
    uwz_websocket *socket,
    uwz_slice message,
    uwz_ws_opcode opcode
);
uwz_error uwz_websocket_send_close(
    uwz_websocket *socket,
    uint16_t code,
    uwz_slice reason
);
size_t uwz_websocket_buffered_amount(const uwz_websocket *socket);
uwz_error uwz_websocket_subscribe(uwz_websocket *socket, uwz_slice topic);
bool uwz_websocket_unsubscribe(uwz_websocket *socket, uwz_slice topic);
size_t uwz_websocket_publish(
    uwz_websocket *socket,
    uwz_slice topic,
    uwz_slice message,
    bool is_text
);
void uwz_websocket_terminate(uwz_websocket *socket);

#ifdef __cplusplus
}
#endif

#endif
