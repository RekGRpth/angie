#!/usr/bin/perl

# (C) 2026 Web Server LLC
# (C) Sergey Kandaurov
# (C) Nginx, Inc.
# (C) Maxim Dounin

# Tests for max_headers directive, HTTP/2.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2/);

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

        http2 on;
        max_headers 5;

        location / { }
    }
}

EOF

$t->write_file('index.html', '');
$t->plan(3)->run();

###############################################################################

is(get('/', ('Foo: bar') x 2), '200', 'two headers');
is(get('/', ('Foo: bar') x 5), '200', 'five headers');
is(get('/', ('Foo: bar') x 6), '400',
	'six headers rejected - max headers reached');

###############################################################################

sub get {
	my ($url, @headers) = @_;

	my $s = Test::Nginx::HTTP2->new();
	my $sid = $s->new_stream({
		headers => [
			{ name => ':method', value => 'GET' },
			{ name => ':scheme', value => 'http' },
			{ name => ':path', value => $url },
			{ name => ':authority', value => 'localhost' },
			map {
				my ($n, $v) = split /:/;
				{ name => lc $n, value => $v, mode => 2 };
			} @headers
		]
	});

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	return $frame->{headers}->{':status'};
}

###############################################################################
