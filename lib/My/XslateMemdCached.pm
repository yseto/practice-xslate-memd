package My::XslateMemdCached;

use strict;
use warnings;
use utf8;

use parent "Text::Xslate";

use Cache::Memcached::Fast;
use Stream::Buffered;

# stolen from mainly Text::Xslate

BEGIN {
    my $dump_load = scalar($Text::Xslate::Util::DEBUG =~ /\b dump=load \b/xms);
    *_DUMP_LOAD = sub(){ $dump_load };

    *_ST_MTIME = sub() { 9 }; # see perldoc -f stat
}

sub options {
    my ($self) = @_;
    +{
        %{$self->SUPER::options(@_)},

        # memcache key prefix
        cache_prefix    => "xslate",
        # memd
        memd            => Cache::Memcached::Fast->new({servers => ["localhost:11211"]}),
    };
}

# determine cache key, template file path.
# called from load_file
# modify determine memcache key.
sub find_file {
    my($self, $file) = @_;

    my $fullpath;
    foreach my $p(@{$self->{path}}) {
        $self->note("  find_file: %s in  %s ...\n", $file, $p) if _DUMP_LOAD;

        # support only virtual path ???
        if(ref $p eq 'HASH') { # virtual path
            defined(my $content = $p->{$file}) or next;
            $fullpath = \$content;
        }
        else {
            die __PACKAGE__ . " is Not Supported";
        }

        last;
    }

    if (not defined $fullpath) {
        die "Not reached! Content is Not Found";
    }

    return {
        name        => $file,
        fullpath    => $fullpath,
        # memcache key
        cachepath   => sprintf("%s:%s", $self->{cache_prefix}, $file),

        orig_mtime  => 0,
        cache_mtime => 0,
    };
}

# called from load_file
sub _load_source {
    my($self, $fi) = @_;
    my $fullpath  = $fi->{fullpath};
    my $cachepath = $fi->{cachepath};

    $self->note("  _load_source: try %s ...\n", $fullpath) if _DUMP_LOAD;

    $self->{memd}->delete($cachepath);

    my $source = $self->slurp_template($self->input_layer, $fullpath);
    $source = $self->{pre_process_handler}->($source) if $self->{pre_process_handler};
#   $self->{source}{$fi->{name}} = $source if _SAVE_SRC;

    my $asm = $self->compile($source,
        file => $fullpath,
        name => $fi->{name},
    );

    if($self->{cache} >= 1) {
        $self->_save_compiled($cachepath, $asm, $fullpath, utf8::is_utf8($source));
    }
    return $asm;
}

# load compiled templates if they are fresh enough
sub _load_compiled {
    my($self, $fi, $threshold) = @_;

    my $cachepath = $fi->{cachepath};

    $self->note( "  _load_compiled: cache: %s",
        $cachepath) if _DUMP_LOAD;

    if($self->{cache} >= 2) {
        # threshold is the most latest modified time of all the related caches,
        # so if the cache level >= 2, they seems always fresh.
        $threshold = 9**9**9; # force to purge the cache
    }
    else {
        $threshold ||= $fi->{cache_mtime};
    }
    # see also tx_load_template() in xs/Text-Xslate.xs
    if(!( defined($fi->{cache_mtime}) and $self->{cache} >= 1
            and $threshold >= $fi->{orig_mtime} )) {
        $self->note( "  _load_compiled: no fresh cache: %s, %s",
            $threshold || 0, Text::Xslate::Util::p($fi) ) if _DUMP_LOAD;
        $fi->{cache_mtime} = undef;
        return undef;
    }

    # get from memcached
    my $in_raw = $self->{memd}->get($cachepath);
    # create temporary buffer
    my $buf = Stream::Buffered->new(1024 * 128);

    if (not defined $in_raw) {
        return undef;
    } else {
        # write to buffer
        $buf->print($in_raw);
    }

    my $in = $buf->rewind;

    my $magic = $self->_magic_token($fi->{fullpath});
    my $data;
    read $in, $data, length($magic);
    if($data ne $magic) {
        return undef;
    }
    else {
        local $/;
        $data = <$in>;
        close $in;
    }
    my $unpacker = Data::MessagePack::Unpacker->new();
    my $offset  = $unpacker->execute($data);
    my $is_utf8 = $unpacker->data();
    $unpacker->reset();

    $unpacker->utf8($is_utf8);

    my @asm;
    if($is_utf8) { # TODO: move to XS?
        my $seed = "";
        utf8::upgrade($seed);
        push @asm, ['print_raw_s', $seed, __LINE__, __FILE__];
    }
    while($offset < length($data)) {
        $offset = $unpacker->execute($data, $offset);
        my $c = $unpacker->data();
        $unpacker->reset();

        # XXX below not tested.

        # my($name, $arg, $line, $file, $symbol) = @{$c};
        if($c->[0] eq 'depend') {
            my $dep_mtime = (stat $c->[1])[_ST_MTIME];
            if(!defined $dep_mtime) {
                Carp::carp("Xslate: Failed to stat $c->[1] (ignored): $!");
                return undef; # purge the cache
            }
            if($dep_mtime > $threshold){
                $self->note("  _load_compiled: %s(%s) is newer than %s(%s)\n",
                    $c->[1],    scalar localtime($dep_mtime),
                    $cachepath, scalar localtime($threshold) )
                        if _DUMP_LOAD;
                return undef; # purge the cache
            }
        }
        elsif($c->[0] eq 'literal') {
            # force upgrade to avoid UTF-8 key issues
            utf8::upgrade($c->[1]) if($is_utf8);
        }
        push @asm, $c;
    }

    if(_DUMP_LOAD) {
        $self->note("  _load_compiled: cache(mtime=%s)\n",
            defined $fi->{cache_mtime} ? $fi->{cache_mtime} : 'undef');
    }

    return \@asm;
}

sub _save_compiled {
    my($self, $cachepath, $asm, $fullpath, $is_utf8) = @_;

    $self->note("  _save_compiled: try %s %s ...\n", $cachepath, $fullpath) if _DUMP_LOAD;

    # create temporary buffer
    my $out = Stream::Buffered->new(1024 * 128);

    my $mp = Data::MessagePack->new();
    local $\;

    $out->print($self->_magic_token($fullpath));
    $out->print($mp->pack($is_utf8 ? 1 : 0));

    foreach my $c(@{$asm}) {
        $out->print($mp->pack($c));
    }

    my $fh = $out->rewind;
    # write to memcached
    $self->{memd}->set($cachepath, do { local $/; <$fh>});

    return 0; # XXX $newest_mtime
}

1;

