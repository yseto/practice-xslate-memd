#!perl -w

use strict;
use warnings;
use feature qw/say/;

use Data::Dumper;
use File::Slurp;
use FindBin;
use lib "$FindBin::Bin/lib/";

$ENV{XSLATE} = "dump=load";
require My::XslateMemdCached;

my $filename = "$FindBin::Bin/hello.tx";
my $buf = read_file($filename);

my $memd = Cache::Memcached::Fast->new({servers => ["127.0.0.1:11211"]});

my $tx = My::XslateMemdCached->new(
    path    => +{
        $filename => $buf,
    },
    memd    => $memd,
    cache   => 2,
);

say $tx->render($filename, { });
say $tx->render($filename, { lang => "Xslate" });

say "-" x 40;

my $fi = $tx->find_file($filename);

my $magic = $tx->_magic_token($fi->{fullpath});

my $cache = $memd->get($fi->{cachepath});
my $data = substr($cache,0, length($magic));

if ($data eq $magic) {
    say "cache magic ok";
} else {
    say "cache magic ng";
}

