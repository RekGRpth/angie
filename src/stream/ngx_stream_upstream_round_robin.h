
/*
 * Copyright (C) 2023 Web Server LLC
 * Copyright (C) Igor Sysoev
 * Copyright (C) Nginx, Inc.
 */


#ifndef _NGX_STREAM_UPSTREAM_ROUND_ROBIN_H_INCLUDED_
#define _NGX_STREAM_UPSTREAM_ROUND_ROBIN_H_INCLUDED_


#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_stream.h>


#define NGX_STREAM_UPSTREAM_SID_LEN   32


#if (NGX_API && NGX_STREAM_UPSTREAM_ZONE)

typedef struct {
    uint64_t                         conns;
    uint64_t                         fails;
    uint64_t                         unavailable;
    uint64_t                         sent;
    uint64_t                         received;
    time_t                           selected;

    uint64_t                         downtime;
    uint64_t                         downstart;
} ngx_stream_upstream_peer_stats_t;

#endif


typedef struct ngx_stream_upstream_rr_peer_s   ngx_stream_upstream_rr_peer_t;
typedef struct ngx_stream_upstream_rr_peers_s  ngx_stream_upstream_rr_peers_t;


#if (NGX_STREAM_UPSTREAM_ZONE)

typedef struct {
    ngx_event_t                      event;    /* must be first */
    ngx_uint_t                       worker;
    ngx_str_t                        name;
    ngx_str_t                        service;
    time_t                           valid;
    ngx_stream_upstream_rr_peers_t  *peers;
    ngx_stream_upstream_rr_peer_t   *peer;
} ngx_stream_upstream_host_t;

#endif


struct ngx_stream_upstream_rr_peer_s {
    struct sockaddr                 *sockaddr;
    socklen_t                        socklen;
    ngx_str_t                        name;
    ngx_str_t                        server;

    ngx_int_t                        current_weight;
    ngx_int_t                        effective_weight;
    ngx_int_t                        weight;

    ngx_uint_t                       conns;
    ngx_uint_t                       max_conns;

    ngx_uint_t                       fails;
    time_t                           accessed;
    time_t                           checked;

    ngx_uint_t                       max_fails;
    time_t                           fail_timeout;
    ngx_msec_t                       slow_start;
    ngx_msec_t                       slow_time;

    ngx_uint_t                       down;

#if (NGX_STREAM_UPSTREAM_SID)
    ngx_str_t                        sid;
#endif

    void                            *ssl_session;
    int                              ssl_session_len;

#if (NGX_STREAM_UPSTREAM_ZONE)
    ngx_atomic_t                     lock;
#endif

    ngx_stream_upstream_rr_peer_t   *next;

#if (NGX_STREAM_UPSTREAM_ZONE)
    ngx_uint_t                       refs;
    ngx_stream_upstream_host_t      *host;
#endif

#if (NGX_API && NGX_STREAM_UPSTREAM_ZONE)
    ngx_stream_upstream_peer_stats_t  stats;
#endif

#if (NGX_STREAM_UPSTREAM_ZONE)
    ngx_msec_t                      zombie;
#endif

    NGX_COMPAT_BEGIN(25)
    NGX_COMPAT_END
};


struct ngx_stream_upstream_rr_peers_s {
    ngx_uint_t                       number;

#if (NGX_STREAM_UPSTREAM_ZONE)
    ngx_slab_pool_t                 *shpool;
    ngx_atomic_t                     rwlock;
    ngx_stream_upstream_rr_peers_t  *zone_next;
#endif

    ngx_uint_t                       total_weight;
    ngx_uint_t                       tries;

    unsigned                         single:1;
    unsigned                         weighted:1;

    ngx_str_t                       *name;

    ngx_stream_upstream_rr_peers_t  *next;

    ngx_stream_upstream_rr_peer_t   *peer;

#if (NGX_STREAM_UPSTREAM_ZONE)
    ngx_uint_t                      *generation;
    ngx_stream_upstream_rr_peer_t   *resolve;
#endif

    ngx_uint_t                       zombies;
};


#if (NGX_API)

typedef struct {
    ngx_stream_upstream_rr_peer_t   *peer;
    ngx_stream_upstream_rr_peers_t  *peers;
    ngx_stream_upstream_srv_conf_t  *uscf;
    unsigned                         backup:1;
    unsigned                         locked:1;
} ngx_api_stream_upstream_peers_ctx_t;


ngx_int_t ngx_api_stream_upstream_peer_struct_int_handler(
    ngx_api_entry_data_t data, ngx_api_ctx_t *actx, void *ctx);
ngx_int_t ngx_api_stream_upstream_peer_struct_int64_handler(
    ngx_api_entry_data_t data, ngx_api_ctx_t *actx, void *ctx);

#endif


#define ngx_stream_upstream_rr_is_failed(peer)                                \
    (peer->max_fails && peer->fails >= peer->max_fails)

#define ngx_stream_upstream_rr_is_fail_expired(peer)                          \
    (ngx_time() - peer->checked > peer->fail_timeout)

#define ngx_stream_upstream_rr_is_busy(peer)                                  \
    (peer->max_conns && peer->conns >= peer->max_conns)


#if (NGX_STREAM_UPSTREAM_ZONE)

#define ngx_stream_upstream_rr_peers_rlock(peers)                             \
                                                                              \
    if (peers->shpool) {                                                      \
        ngx_rwlock_rlock(&peers->rwlock);                                     \
    }

#define ngx_stream_upstream_rr_peers_wlock(peers)                             \
                                                                              \
    if (peers->shpool) {                                                      \
        ngx_rwlock_wlock(&peers->rwlock);                                     \
    }

#define ngx_stream_upstream_rr_peers_unlock(peers)                            \
                                                                              \
    if (peers->shpool) {                                                      \
        ngx_rwlock_unlock(&peers->rwlock);                                    \
    }


#define ngx_stream_upstream_rr_peer_lock(peers, peer)                         \
                                                                              \
    if (peers->shpool) {                                                      \
        ngx_rwlock_wlock(&peer->lock);                                        \
    }

#define ngx_stream_upstream_rr_peer_unlock(peers, peer)                       \
                                                                              \
    if (peers->shpool) {                                                      \
        ngx_rwlock_unlock(&peer->lock);                                       \
    }

#define ngx_stream_upstream_rr_peer_ref(peers, peer)                          \
    (peer)->refs++;


static ngx_inline void
ngx_stream_upstream_rr_peer_free_locked(ngx_stream_upstream_rr_peers_t *peers,
    ngx_stream_upstream_rr_peer_t *peer)
{
    if (peer->refs) {
        peer->zombie = ngx_current_msec;
        peers->zombies++;
        return;
    }

    ngx_slab_free_locked(peers->shpool, peer->sockaddr);
    ngx_slab_free_locked(peers->shpool, peer->name.data);

    if (peer->server.data) {
        ngx_slab_free_locked(peers->shpool, peer->server.data);
    }

#if (NGX_STREAM_UPSTREAM_SID)
    if (peer->sid.data
        && (peer->host == NULL
            || peer->host->peer == peer
            || peer->host->peer->sid.len == 0))
    {
        ngx_slab_free_locked(peers->shpool, peer->sid.data);
    }
#endif

#if (NGX_STREAM_SSL)
    if (peer->ssl_session) {
        ngx_slab_free_locked(peers->shpool, peer->ssl_session);
    }
#endif

    ngx_slab_free_locked(peers->shpool, peer);
}


static ngx_inline void
ngx_stream_upstream_rr_peer_free(ngx_stream_upstream_rr_peers_t *peers,
    ngx_stream_upstream_rr_peer_t *peer)
{
    ngx_shmtx_lock(&peers->shpool->mutex);
    ngx_stream_upstream_rr_peer_free_locked(peers, peer);
    ngx_shmtx_unlock(&peers->shpool->mutex);
}


static ngx_inline ngx_int_t
ngx_stream_upstream_rr_peer_unref(ngx_stream_upstream_rr_peers_t *peers,
    ngx_stream_upstream_rr_peer_t *peer)
{
    peer->refs--;

    if (peers->shpool == NULL) {
        return NGX_OK;
    }

    if (peer->refs == 0 && peer->zombie) {
        ngx_shmtx_lock(&peers->shpool->mutex);

        ngx_stream_upstream_rr_peer_free_locked(peers, peer);
        peers->zombies--;

        ngx_shmtx_unlock(&peers->shpool->mutex);

        return NGX_DONE;
    }

    return NGX_OK;
}

#else

#define ngx_stream_upstream_rr_peers_rlock(peers)
#define ngx_stream_upstream_rr_peers_wlock(peers)
#define ngx_stream_upstream_rr_peers_unlock(peers)
#define ngx_stream_upstream_rr_peer_lock(peers, peer)
#define ngx_stream_upstream_rr_peer_unlock(peers, peer)
#define ngx_stream_upstream_rr_peer_ref(peers, peer)
#define ngx_stream_upstream_rr_peer_unref(peers, peer)  NGX_OK

#endif


typedef struct {
    ngx_uint_t                       generation;
    ngx_stream_upstream_rr_peers_t  *peers;
    ngx_stream_upstream_rr_peer_t   *current;
    uintptr_t                       *tried;
    uintptr_t                        data;
} ngx_stream_upstream_rr_peer_data_t;


ngx_int_t ngx_stream_upstream_init_round_robin(ngx_conf_t *cf,
    ngx_stream_upstream_srv_conf_t *us);
void ngx_stream_upstream_set_round_robin_single(
    ngx_stream_upstream_srv_conf_t *us);
ngx_int_t ngx_stream_upstream_init_round_robin_peer(ngx_stream_session_t *s,
    ngx_stream_upstream_srv_conf_t *us);
ngx_int_t ngx_stream_upstream_create_round_robin_peer(ngx_stream_session_t *s,
    ngx_stream_upstream_resolved_t *ur);
ngx_int_t ngx_stream_upstream_get_round_robin_peer(ngx_peer_connection_t *pc,
    void *data);
void ngx_stream_upstream_use_rr_peer(ngx_peer_connection_t *pc,
    ngx_stream_upstream_rr_peer_data_t *rrp,
    ngx_stream_upstream_rr_peer_t *peer, ngx_uint_t index);
void ngx_stream_upstream_free_round_robin_peer(ngx_peer_connection_t *pc,
    void *data, ngx_uint_t state);

#if (NGX_STREAM_UPSTREAM_SID)
void ngx_stream_upstream_rr_peer_init_sid(ngx_stream_upstream_rr_peer_t *peer);
#endif


static ngx_inline ngx_uint_t
ngx_stream_upstream_throttle_peer(ngx_stream_upstream_rr_peer_t *peer)
{
    ngx_uint_t  factor;

    if (peer->slow_time) {
        factor = (ngx_current_msec - peer->slow_time) * 100 / peer->slow_start;

        if (factor < 100) {
            return factor;
        }

        peer->slow_time = 0;
    }

    return 100;
}


#endif /* _NGX_STREAM_UPSTREAM_ROUND_ROBIN_H_INCLUDED_ */
