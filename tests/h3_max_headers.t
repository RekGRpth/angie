#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.
# (C) 2025 Web Server LLC
# (C) Maxim Dounin

# Tests for max_headers directive, HTTP/3.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v3 cryptx/)
	->has_daemon('openssl');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_certificate localhost.crt;
    ssl_certificate_key localhost.key;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        server_name  localhost;

        max_headers 5;

        location / { }
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

foreach my $name ('localhost') {
	system('openssl req -x509 -new '
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.crt -keyout $d/$name.key "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

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

	my $s = Test::Nginx::HTTP3->new();
	my $sid = $s->new_stream({
		headers => [
			{ name => ':method', value => 'GET' },
			{ name => ':scheme', value => 'http' },
			{ name => ':path', value => $url },
			{ name => ':authority', value => 'localhost' },
			map {
				my ($n, $v) = split /:/;
				{ name => lc $n, value => $v };
			} @headers
		]
	});

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	return $frame->{headers}->{':status'};
}

###############################################################################
