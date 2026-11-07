#ifndef TVPAIR_TLS_H
#define TVPAIR_TLS_H
#include <stddef.h>
#include <stdint.h>

typedef struct tvp_tls_engine tvp_tls_engine;
// Each engine is owned by one Swift actor. No process-global credentials.
enum { TVP_TLS_ERROR = -1, TVP_TLS_CLOSED = -2, TVP_TLS_NEED_INPUT = 0, TVP_TLS_DONE = 1 };
tvp_tls_engine *tvp_tls_create(const uint8_t *key, size_t length);
void tvp_tls_free(tvp_tls_engine *engine);
int tvp_tls_handshake(tvp_tls_engine *engine);
int tvp_tls_feed(tvp_tls_engine *engine, const uint8_t *bytes, size_t length);
int tvp_tls_drain(tvp_tls_engine *engine, uint8_t *bytes, size_t capacity);
int tvp_tls_write(tvp_tls_engine *engine, const uint8_t *bytes, size_t length, size_t *written);
int tvp_tls_read(tvp_tls_engine *engine, uint8_t *bytes, size_t capacity, size_t *read_count);
uint16_t tvp_tls_cipher(tvp_tls_engine *engine);
int32_t tvp_tls_error(tvp_tls_engine *engine);
#endif
