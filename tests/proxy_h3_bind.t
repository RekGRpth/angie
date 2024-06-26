#!/usr/bin/perl

# (C) Andrey Zelenkov
# (C) Nginx, Inc.
# (C) 2023 Web Server LLC

# Tests for http proxy_bind directive.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

plan(skip_all => 'win32') if $^O eq 'MSWin32';
plan(skip_all => '127.0.0.2 local address required')
	unless defined IO::Socket::INET->new( LocalAddr => '127.0.0.2' );

my $t = Test::Nginx->new()->has(qw/http proxy http_v3/)
	->has_daemon("openssl")->plan(5);

$t->prepare_ssl();

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen          127.0.0.1:8080;
        server_name     localhost;

        proxy_bind      127.0.0.2;

        location / {
            proxy_bind  127.0.0.1;
            proxy_pass  https://127.0.0.1:%%PORT_8999_UDP%%/;
            proxy_http_version  3;
        }

        location /inherit {
            proxy_pass  https://127.0.0.1:%%PORT_8999_UDP%%/;
            proxy_http_version  3;
        }

        location /off {
            proxy_bind  off;
            proxy_pass  https://127.0.0.1:%%PORT_8999_UDP%%/;
            proxy_http_version  3;
        }

        location /var {
            proxy_bind  $arg_b;
            proxy_pass  https://127.0.0.1:%%PORT_8999_UDP%%/;
            proxy_http_version  3;
        }

        location /port {
            proxy_bind  127.0.0.2:$remote_port;
            proxy_pass  https://127.0.0.1:%%PORT_8999_UDP%%/;
            proxy_http_version  3;
            add_header  X-Client-Port $remote_port;
        }
    }

    server {
        ssl_certificate_key localhost.key;
        ssl_certificate localhost.crt;

        listen          127.0.0.1:%%PORT_8999_UDP%% quic;
        server_name     localhost;

        location / {
            add_header   X-IP $remote_addr;
            add_header   X-Port $remote_port;
        }
    }
}

EOF

$t->write_file('index.html', '');
$t->run();

###############################################################################

like(http_get('/'), qr/x-ip: 127.0.0.1/, 'bind');
like(http_get('/inherit'), qr/x-ip: 127.0.0.2/, 'bind inherit');
like(http_get('/off'), qr/x-ip: 127.0.0.1/, 'bind off');
like(http_get('/var?b=127.0.0.2'), qr/x-ip: 127.0.0.2/, 'bind var');
like(http_get('/port'), qr/port: (\d+)(?!\d).*Port: \1/s, 'bind port');

###############################################################################
