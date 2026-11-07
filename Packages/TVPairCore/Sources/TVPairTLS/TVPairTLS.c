#include "TVPairTLS.h"
#include <OpenSSL/ssl.h>
#include <OpenSSL/err.h>
#include <OpenSSL/crypto.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

struct tvp_tls_engine {
    SSL_CTX *context;
    SSL *ssl;
    uint8_t key[64];
    size_t key_length;
    int32_t error;
    int ready;
};

static unsigned int supply_psk(SSL *ssl, const char *hint, char *identity,
                              unsigned int identity_capacity, unsigned char *key,
                              unsigned int key_capacity) {
    (void)hint;
    tvp_tls_engine *engine = SSL_get_app_data(ssl);
    if (!engine || !identity || identity_capacity < 1 || !key || key_capacity < engine->key_length) return 0;
    identity[0] = '\0'; // The reference protocol uses an empty identity.
    memcpy(key, engine->key, engine->key_length);
    return (unsigned int)engine->key_length;
}

static int status(tvp_tls_engine *engine, int result) {
    if (result == 1) return TVP_TLS_DONE;
    int error = SSL_get_error(engine->ssl, result);
    if (error == SSL_ERROR_WANT_READ) return TVP_TLS_NEED_INPUT;
    if (error == SSL_ERROR_ZERO_RETURN) return TVP_TLS_CLOSED;
    unsigned long detail = ERR_peek_last_error();
    engine->error = detail ? (int32_t)ERR_GET_REASON(detail) : -error;
    // Memory BIO writes cannot block. WANT_WRITE and all other errors fail closed.
    return TVP_TLS_ERROR;
}

tvp_tls_engine *tvp_tls_create(const uint8_t *key, size_t length) {
    if (!key || length == 0 || length > 64) return NULL;
    tvp_tls_engine *engine = calloc(1, sizeof(*engine));
    if (!engine) return NULL;
    memcpy(engine->key, key, length);
    engine->key_length = length;
    ERR_clear_error();
    engine->context = SSL_CTX_new(TLS_client_method());
    if (!engine->context) goto fail;
    if (!SSL_CTX_set_min_proto_version(engine->context, TLS1_2_VERSION) ||
        !SSL_CTX_set_max_proto_version(engine->context, TLS1_2_VERSION) ||
        !SSL_CTX_set_cipher_list(engine->context, "PSK-AES256-CBC-SHA384:PSK-AES128-CBC-SHA")) goto fail;
    SSL_CTX_set_options(engine->context, SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION | SSL_OP_NO_TICKET);
    SSL_CTX_set_session_cache_mode(engine->context, SSL_SESS_CACHE_OFF);
    SSL_CTX_set_verify(engine->context, SSL_VERIFY_PEER, NULL);
    SSL_CTX_set_psk_client_callback(engine->context, supply_psk);
    engine->ssl = SSL_new(engine->context);
    if (!engine->ssl) goto fail;
    BIO *input = BIO_new(BIO_s_mem()), *output = BIO_new(BIO_s_mem());
    if (!input || !output) { BIO_free(input); BIO_free(output); goto fail; }
    BIO_set_mem_eof_return(input, -1);
    SSL_set_bio(engine->ssl, input, output); // SSL takes ownership of both BIOs.
    SSL_set_app_data(engine->ssl, engine);
    SSL_set_mode(engine->ssl, SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    SSL_set_connect_state(engine->ssl);
    return engine;
fail:
    tvp_tls_free(engine);
    return NULL;
}

void tvp_tls_free(tvp_tls_engine *engine) {
    if (!engine) return;
    SSL_free(engine->ssl);
    SSL_CTX_free(engine->context);
    OPENSSL_cleanse(engine, sizeof(*engine));
    free(engine);
}

uint16_t tvp_tls_cipher(tvp_tls_engine *engine) {
    if (!engine || !engine->ready) return 0;
    const SSL_CIPHER *cipher = SSL_get_current_cipher(engine->ssl);
    return cipher ? SSL_CIPHER_get_protocol_id(cipher) : 0;
}

int tvp_tls_handshake(tvp_tls_engine *engine) {
    if (!engine) return TVP_TLS_ERROR;
    ERR_clear_error();
    int result = status(engine, SSL_do_handshake(engine->ssl));
    if (result == TVP_TLS_DONE) {
        engine->ready = 1;
        uint16_t cipher = tvp_tls_cipher(engine);
        if (SSL_version(engine->ssl) != TLS1_2_VERSION || (cipher != 0x00af && cipher != 0x008c)) {
            engine->ready = 0; engine->error = -100; return TVP_TLS_ERROR;
        }
    }
    return result;
}

int tvp_tls_feed(tvp_tls_engine *engine, const uint8_t *bytes, size_t length) {
    if (!engine || !bytes || length > 18437) return TVP_TLS_ERROR;
    BIO *input = SSL_get_rbio(engine->ssl);
    if (BIO_ctrl_pending(input) + length > 65536) return TVP_TLS_ERROR;
    return BIO_write(input, bytes, (int)length) == (int)length ? TVP_TLS_DONE : TVP_TLS_ERROR;
}

int tvp_tls_drain(tvp_tls_engine *engine, uint8_t *bytes, size_t capacity) {
    if (!engine || !bytes || capacity == 0 || capacity > INT_MAX) return TVP_TLS_ERROR;
    BIO *output = SSL_get_wbio(engine->ssl);
    if (BIO_ctrl_pending(output) == 0) return 0;
    int count = BIO_read(output, bytes, (int)capacity);
    return count > 0 ? count : TVP_TLS_ERROR;
}

int tvp_tls_write(tvp_tls_engine *engine, const uint8_t *bytes, size_t length, size_t *written) {
    if (!engine || !engine->ready || !bytes || !written || length > 16384) return TVP_TLS_ERROR;
    ERR_clear_error();
    return status(engine, SSL_write_ex(engine->ssl, bytes, length, written));
}

int tvp_tls_read(tvp_tls_engine *engine, uint8_t *bytes, size_t capacity, size_t *read_count) {
    if (!engine || !engine->ready || !bytes || !read_count || capacity > 16384) return TVP_TLS_ERROR;
    ERR_clear_error();
    return status(engine, SSL_read_ex(engine->ssl, bytes, capacity, read_count));
}

int32_t tvp_tls_error(tvp_tls_engine *engine) { return engine ? engine->error : -101; }
