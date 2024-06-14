#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.
# (C) Hiroaki Nakamura

# Tests for age in HTTP/2 proxy cache.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

use POSIX qw/ ceil /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 proxy cache/)->plan(10)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path %%TESTDIR%%/cache    keys_zone=NAME:1m;
    proxy_cache_path %%TESTDIR%%/cache2   keys_zone=NAME2:1m;

    map $arg_slow $rate {
        default 8k;
        1       90;
    }

    server {
        listen       127.0.0.1:8080 http2;
        server_name  localhost;
        error_log    %%TESTDIR%%/error8080.log debug;

        location / {
            proxy_pass             http://127.0.0.1:8081;
            proxy_cache            NAME;
            proxy_http_version     1.1;
            proxy_cache_revalidate on;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;
        error_log    %%TESTDIR%%/error8081.log debug;

        location / {
            proxy_pass             http://127.0.0.1:8082;
            proxy_cache            NAME2;
            proxy_http_version     1.1;
            proxy_cache_revalidate on;
        }
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;
        error_log    %%TESTDIR%%/error8082.log debug;

        location / {
            add_header Cache-Control s-maxage=$arg_ttl;
            limit_rate $rate;
        }
    }
}

EOF

$t->write_file('t.html', 'SEE-THIS');
$t->write_file('t2.html', 'SEE-THIS');
$t->write_file('t3.html', 'SEE-THIS');

# suppress deprecation warning

open OLDERR, ">&", \*STDERR; close STDERR;
$t->run();
open STDERR, ">&", \*OLDERR;

###############################################################################

my $s = Test::Nginx::HTTP2->new();

my ($path, $sid, $frames, $frame, $t1, $age);

# normal origin

wait_until_next_second();

$path = '/t.html?ttl=2';

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, undef, 'age first');

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 0, 'age hit');

select undef, undef, undef, 2.0;

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 2, 'age hit');

select undef, undef, undef, 1.0;

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, undef, 'age updated');

SKIP: {
skip 'no exec on win32', 3 if $^O eq 'MSWin32';

# slow origin

wait_until_next_second();

$path = '/t2.html?ttl=10&slow=1';

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, undef, 'slow origin first');

select undef, undef, undef, 2.0;

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, 2, 'slow origin hit');

select undef, undef, undef, 9.0;

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, undef, 'slow origin updated');
$t1 = time();

$t->stop();

select undef, undef, undef, 1.0;

open OLDERR, ">&", \*STDERR; close STDERR;
$t->run();
open STDERR, ">&", \*OLDERR;

$age = time() - $t1;

$s = Test::Nginx::HTTP2->new();

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, $age, 'age after restart');

}

# update age after restart

wait_until_next_second();

$path = '/t3.html?ttl=20';

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, undef, 'age before restart');
$t1 = time();

$t->stop();

select undef, undef, undef, 1.0;

open OLDERR, ">&", \*STDERR; close STDERR;
$t->run();
open STDERR, ">&", \*OLDERR;

$age = time() - $t1;

$s = Test::Nginx::HTTP2->new();

$sid = $s->new_stream({ path => $path });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{'age'}, $age, 'age after restart');

$t->stop();

###############################################################################

# Wait until the next second boundary.
# Calling this before sending a request increases the likelihood that the
# timestamp value does not cross into the next second while sending a request
# and receiving a response.
sub wait_until_next_second {
    my $now = time();
    my $next_second = ceil($now);
    my $sleep = $next_second - $now;
    select undef, undef, undef, $sleep;
}

###############################################################################
