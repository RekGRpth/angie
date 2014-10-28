#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for the proxy_limit_rate directive.

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

my $t = Test::Nginx->new()->has(qw/http proxy/);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            proxy_pass http://127.0.0.1:8080/data;
            proxy_limit_rate 12000;
        }

        location /data {
        }
    }
}

EOF

$t->write_file('data', 'X' x 40000);
$t->try_run('no proxy_limit_rate')->plan(2);

###############################################################################

my $t1 = time();

my $r = http_get('/');

my $diff = time() - $t1;

# four chunks are split with three 1s delays + 1s error

cmp_ok(abs($diff - 3), '<=', 1, 'proxy_limit_rate');
like($r, qr/^(XXXXXXXXXX){4000}\x0d?\x0a?$/m, 'response body');

###############################################################################
