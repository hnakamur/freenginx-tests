#!/usr/bin/perl

# (C) Maxim Dounin
# (C) Sergey Kandaurov
# (C) Andrey Zelenkov
# (C) Nginx, Inc.

# Tests for stream geo module.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream stream_return stream_map stream_geo/);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    geo $geo {
        127.0.0.0/8   loopback;
        192.0.2.0/24  test;
        0.0.0.0/0     world;
    }

    geo $geo_include {
        include       geo.conf;
        192.0.2.0/24  test;
        0.0.0.0/0     world;
    }

    geo $geo_delete {
        127.0.0.0/8   loopback;
        192.0.2.0/24  test;
        0.0.0.0/0     world;
        delete        127.0.0.0/8;
    }

    geo $remote_addr $geo_from_addr {
        127.0.0.0/8   loopback;
        192.0.2.0/24  test;
    }

    map $server_port $var {
        %%PORT_8080%%  "192.0.2.1";
        %%PORT_8081%%  "10.0.0.1";
        %%PORT_8085%%  "10.11.2.1";
    }

    geo $var $geo_from_var {
        default       default;
        127.0.0.0/8   loopback;
        192.0.2.0/24  test;
    }

    geo $var $geo_var_ranges {
        ranges;
        default                default;

        # ranges with two /16 networks
        # the latter network has greater two least octets
        # (see 1301a58b5dac for details)
        10.10.3.0-10.11.2.255  foo;
        delete                 10.10.3.0-10.11.2.255;
    }

    geo $var $geo_world {
        127.0.0.0/8   loopback;
        192.0.2.0/24  test;
        0.0.0.0/0     world;
    }

    geo $geo_ranges {
        ranges;
        default                    default;
        127.0.0.0-127.255.255.255  loopback;
        192.0.2.0-192.0.2.255      test;
    }

    geo $geo_ranges_include {
        ranges;
        default                default;
        include                geo-ranges.conf;
        192.0.2.0-192.0.2.255  test;
    }

    geo $geo_ranges_delete {
        ranges;
        default                default;
        127.0.0.0-127.0.0.255  test;
        127.0.0.1-127.0.0.1    loopback;
        delete                 127.0.0.0-127.0.0.0;
        delete                 127.0.0.2-127.0.0.255;
        delete                 127.0.0.1-127.0.0.1;
    }

    # delete range with two /16
    geo $geo_ranges_delete_2 {
        ranges;
        default              default;
        127.0.0.0-127.1.0.0  loopback;
        delete               127.0.0.0-127.1.0.0;
    }

    server {
        listen  127.0.0.1:8080;
        return  "geo:$geo
                 geo_include:$geo_include
                 geo_delete:$geo_delete
                 geo_ranges:$geo_ranges
                 geo_ranges_include:$geo_ranges_include
                 geo_from_addr:$geo_from_addr
                 geo_from_var:$geo_from_var";
    }

    server {
        listen  127.0.0.1:8081;
        return  $geo_from_var;
    }

    server {
        listen  127.0.0.1:8082;
        return  $geo_world;
    }

    server {
        listen  127.0.0.1:8083;
        return  $geo_ranges_delete;
    }

    server {
        listen  127.0.0.1:8084;
        return  $geo_ranges_delete_2;
    }

    server {
        listen  127.0.0.1:8085;
        return  $geo_var_ranges;
    }
}

EOF

$t->write_file('geo.conf', '127.0.0.0/8  loopback;');
$t->write_file('geo-ranges.conf', '127.0.0.0-127.255.255.255  loopback;');

$t->try_run('no stream geo')->plan(12);

###############################################################################

my %data = stream()->read() =~ /(\w+):(\w+)/g;
is($data{geo}, 'loopback', 'geo');
is($data{geo_include}, 'loopback', 'geo include');
is($data{geo_delete}, 'world', 'geo delete');
is($data{geo_ranges}, 'loopback', 'geo ranges');
is($data{geo_ranges_include}, 'loopback', 'geo ranges include');

TODO: {
todo_skip 'use-after-free', 2 unless $ENV{TEST_NGINX_UNSAFE}
	or $t->has_version('1.11.4');

is(stream('127.0.0.1:' . port(8083))->read(), 'default', 'geo ranges delete');
is(stream('127.0.0.1:' . port(8084))->read(), 'default', 'geo ranges delete 2');

}

is($data{geo_from_addr}, 'loopback', 'geo from addr');
is($data{geo_from_var}, 'test', 'geo from var');

TODO: {
todo_skip 'use-after-free', 1 unless $ENV{TEST_NGINX_UNSAFE}
	or $t->has_version('1.11.4');

is(stream('127.0.0.1:' . port(8085))->read(), 'default',
	'geo delete range from variable');

}

is(stream('127.0.0.1:' . port(8081))->read(), 'default', 'geo default');
is(stream('127.0.0.1:' . port(8082))->read(), 'world', 'geo world');

###############################################################################
