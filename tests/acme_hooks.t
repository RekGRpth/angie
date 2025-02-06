#!/usr/bin/perl

# (C) 2024 Web Server LLC

# ACME hooks tests

# This script requires pebble and pebble-challtestsrv
# (see Test::Nginx::ACME for details)

###############################################################################

use warnings;
use strict;

use Socket qw/ CRLF /;
use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::ACME;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

eval { require FCGI; };
plan(skip_all => 'FCGI not installed') if $@;

my $t = Test::Nginx->new()->has(qw/acme socket_ssl/);

# XXX
# We don't use the port function here, because the port it creates is currently
# incompatible with challtestsrv (they both create a pair of tcp/udp sockets on
# the same port number, which eventually results in challtestsrv getting an
# "Address already in use" error).
# While it is not entirely safe to use this port number, this shouldn't cause
# problems in most cases.
my $dns_port = 10053;

my $acme_helper = Test::Nginx::ACME->new({
	t => $t,
	dns_port => $dns_port,
});

my $d = $t->testdir();

my $hook_port = port(9000);
my $http_port = port(5002);
my $pebble_port = port(14000);
my $challtestsrv_mgmt_port = port(8055);

my (@clients, @servers);

my @keys = (
	{ type => 'rsa', bits => 2048 },
	{ type => 'ecdsa', bits => 256 },
);

my @challenges = ('http', 'dns');

my $domain_count = 1;

# Each iteration creates 2 clients, one with the RSA key type, the other with
# the ECDSA. Each subsequent iteration also assigns a different challenge type.
for (1 .. 6) {
	my $n = $_;

	my $chlg = $challenges[($n - 1) % @challenges];

	my $srv = {
		domains => [],
		clients => [],
	};

	for (1 .. 2) {
		push @{ $srv->{domains} }, "angie-test${domain_count}.com";
		$domain_count++;
	}

	if ($chlg eq 'dns') {
		# The dns-01 validation method allows wildcard domain names.
		push @{ $srv->{domains} }, "*.angie-test${domain_count}.com";
		$domain_count++;
	}

	for my $key (@keys) {
		my $cli = {
			name => "test${n}_$key->{type}",
			key_type => $key->{type},
			key_bits => $key->{bits},
			challenge => $chlg,
			renewed => 0,
			enddate => "n/a",
		};

		push @clients, $cli;
		push @{ $srv->{clients} }, $cli;
	}

	push @servers, $srv;
}

my $conf_clients = '';
my $conf_servers = '';
my $conf_hooks = '';

my $account_key = '';
my $email = '';

for my $e (@clients) {
	$conf_clients .= "    acme_client $e->{name} "
		. "https://localhost:$pebble_port/dir challenge=$e->{challenge} "
		. "key_type=$e->{key_type} key_bits=$e->{key_bits} "
		. "$account_key $email;\n";

	# for a change...
	$email = ($email eq '' ) ? "email=admin\@angie-test.com" : '';
	$account_key = "account_key=$d/acme_client/$clients[0]->{name}/account.key";

	$conf_hooks .= "            acme_hook $e->{name};\n";
}

for my $e (@servers) {

	$conf_servers .=
"    server {
        listen       localhost:%%PORT_8080%%;
        server_name  @{ $e->{domains} };

";

	for my $cli (@{ $e->{clients} }) {
		$conf_servers .= "        acme $cli->{name};\n";
	}

	$conf_servers .= "    }\n\n";
}

my $conf =
"
%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    resolver localhost:$dns_port ipv6=off;

    server {
        listen       localhost:%%PORT_8080%%;

        location / {
            internal;

$conf_hooks
            fastcgi_pass localhost:$hook_port;

            fastcgi_param ACME_CLIENT           \$acme_hook_client;
            fastcgi_param ACME_HOOK             \$acme_hook_name;
            fastcgi_param ACME_CHALLENGE        \$acme_hook_challenge;
            fastcgi_param ACME_DOMAIN           \$acme_hook_domain;
            fastcgi_param ACME_TOKEN            \$acme_hook_token;
            fastcgi_param ACME_KEYAUTH          \$acme_hook_keyauth;
        }
    }

$conf_servers
$conf_clients
}
";

$t->write_file_expand('nginx.conf', $conf);

$acme_helper->start_challtestsrv({
	http_port => $http_port,
	mgmt_port => $challtestsrv_mgmt_port
});

$acme_helper->start_pebble({
	pebble_port => $pebble_port,
	http_port => $http_port
});

$t->run_daemon(\&hook_handler, $hook_port);

$t->try_run('variables in "ssl_certificate" and "ssl_certificate_key" '
	. 'directives are not supported on this platform', 1);

$t->plan(scalar @clients);

my $renewed_count = 0;
my $loop_start = time();

for (1 .. 20 * @clients) {

	for my $cli (@clients) {
		next if $cli->{renewed};

		my $cert_file = "$d/acme_client/$cli->{name}/certificate.pem";

		if (-e $cert_file && -s $cert_file) {
			my $s = `openssl x509 -in $cert_file -enddate -noout|cut -d= -f 2`;

			next if $s eq '';

			chomp $s;

			$renewed_count++;
			note("$0: $cli->{name} renewed certificate "
				. " ($renewed_count of " . @clients . ")");

			$cli->{renewed} = 1;
			$cli->{enddate} = $s;
		}
	}

	last if $renewed_count == @clients;

	if (!$renewed_count && time() - $loop_start > 20) {
		# If none of the clients has renewed during this time,
		# then there's probably no need to wait longer.
		note("$0: Quitting on timeout ...");
		last;
	}

	sleep 1;
}

for my $cli (@clients) {
	ok($cli->{renewed}, "$cli->{name} renewed certificate " .
		"(challenge: $cli->{challenge}; enddate: $cli->{enddate})");
}

###############################################################################

sub hook_add {
	my ($challenge, $hook, $domain, $token, $keyauth) = @_;

	if ($challenge eq 'http') {
		http_post('/add-http01',
			body => "{\"token\":\"$token\",\"content\":\"$keyauth\"}");

	} elsif ($challenge eq 'dns') {
		my $name = "_acme-challenge.$domain.";

		http_post('/set-txt',
			body => "{\"host\":\"$name\",\"value\":\"$keyauth\"}");
	} else {
		die('Unknown challenge ' . $challenge);
	}
}

sub hook_remove {
	my ($challenge, $hook, $domain, $token, $keyauth) = @_;

	if ($challenge eq 'http') {
		http_post('/del-http01', body => "{\"token\":\"$token\"}");

	} elsif ($challenge eq 'dns') {
		my $name = "_acme-challenge.$domain.";

		http_post('/clear-txt', body => "{\"host\":\"$name\"}");

	} else {
		die('Unknown challenge ' . $challenge);
	}
}

sub hook_handler {
	my $hook_port = shift;

	my $socket = FCGI::OpenSocket(":$hook_port", 5);
	my $req = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

	while ($req->Accept() >= 0) {
		my $client = $ENV{ACME_CLIENT};
		my $hook = $ENV{ACME_HOOK};
		my $challenge = $ENV{ACME_CHALLENGE};
		my $domain = $ENV{ACME_DOMAIN};
		my $token = $ENV{ACME_TOKEN};
		my $keyauth = $ENV{ACME_KEYAUTH};

		if ($hook eq 'add') {
			hook_add($challenge, $hook, $domain, $token, $keyauth);

		} elsif ($hook eq 'remove') {
			hook_remove($challenge, $hook, $domain, $token, $keyauth);

		} else {
			print "Status: 400\r\n";
		}

		print "\r\n";
	}

	FCGI::CloseSocket($socket);
}

###############################################################################

sub http_post {
	my ($url, %extra) = @_;

	my $peer = "127.0.0.1:$challtestsrv_mgmt_port";

	my $s = IO::Socket::INET->new(
		Proto => 'tcp',
		PeerAddr => $peer,
	)
	or die "Can't connect to challtestsrv ($peer): $!\n";

	$extra{socket} = $s;

	my $p = "POST $url HTTP/1.0" . CRLF .
		"Host: localhost" . CRLF .
		"Content-Length: ". length($extra{body}) . CRLF .
		CRLF;

	return http($p, %extra);
}

