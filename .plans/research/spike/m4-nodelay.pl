#!/usr/bin/perl
# M4, 2026-09-26: m4-nodelay.sps's question on Linux, where the Chez toolchain is
# not in the image: does Nagle hold a server's small responses, written one at a
# time as the shell writes them (the next once the kernel took the last)?
# The server answers each request with one write as it parses it; a client
# sends sixteen GETs pipelined in one write, or one at a time, each after the
# last response, three runs each, TCP_NODELAY off then on at the server.
# Milliseconds from /proc/uptime (10 ms resolution): a research reading only.
# Run offline in Docker's debian:trixie (perl-base, no Time::HiRes):
#   docker run --rm --network none -v "$PWD/.plans/research/spike:/w" debian:trixie perl /w/m4-nodelay.pl
use strict;
use warnings;
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use IO::Socket::INET;

sub now {
    open(my $f, '<', '/proc/uptime') or die "no /proc/uptime: $!";
    my ($up) = split ' ', scalar <$f>;
    close $f;
    return $up * 1000;
}

my $get = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
my $body = "hello, world\n";
my $response = "HTTP/1.1 200 OK\r\nDate: Sun, 06 Nov 1994 08:49:37 GMT\r\nContent-Length: "
    . length($body) . "\r\n\r\n" . $body;

sub run_once {
    my ($nodelay, $how) = @_;
    my $srv = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0,
                                    Listen => 5, ReuseAddr => 1) or die "listen: $!";
    my $port = $srv->sockport;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        my $c = $srv->accept or die "accept: $!";
        setsockopt($c, IPPROTO_TCP, TCP_NODELAY, 1) if $nodelay;
        my ($buf, $answered) = ('', 0);
        while ($answered < 16) {
            my $n = sysread($c, $buf, 65536, length $buf);
            last unless $n;
            while ($buf =~ s/^GET [^\r]*\r\nHost: x\r\n\r\n//) {
                syswrite($c, $response);
                $answered++;
            }
        }
        my $rest;
        sysread($c, $rest, 1);
        exit 0;
    }
    close $srv;
    my $cl = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port) or die "connect: $!";
    my ($got, $seen) = ('', 0);
    my $wait_for = sub {
        my ($want) = @_;
        while ($seen < $want) {
            my $n = sysread($cl, $got, 65536, length $got);
            die "closed early" unless $n;
            $seen = () = $got =~ /HTTP\/1\.1 200/g;
        }
    };
    my $start = now();
    if ($how eq 'pipelined') {
        syswrite($cl, $get x 16);
        $wait_for->(16);
    } else {
        for my $i (1 .. 16) {
            syswrite($cl, $get);
            $wait_for->($i);
        }
    }
    my $elapsed = now() - $start;
    close $cl;
    waitpid($pid, 0);
    return $elapsed;
}

for my $nodelay (0, 1) {
    for my $how ('pipelined', 'one-at-a-time') {
        my @t = map { run_once($nodelay, $how) } 1 .. 3;
        printf "TCP_NODELAY %-3s  %s: %s ms\n", ($nodelay ? 'on' : 'off'), $how, join(' ', @t);
    }
}
