##
# name:      Package::Conf
# abstract:  Config Class for Package
# author:    Ingy döt Net <ingy@cpan.org>
# license:   perl
# copyright: 2011
package Package::Conf;
use Mouse;

use Cwd;
use File::Spec;
use Hash::Merge;
use IO::All;
use YAML::XS;

our $author_name_hack;

has src_dir => (
    is => 'ro',
    required => 1,
);
has cli_args => (
    is => 'ro',
    required => 1,
);
has dirs => (
    is => 'ro',
    builder => 'dirs_builder',
    lazy => 1,
);
has stash => (
    is => 'ro',
    builder => 'stash_builder',
    lazy => 1,
);
has manifest => (
    is => 'ro',
    builder => 'manifest_builder',
    lazy => 1,
);

sub dirs_builder {
    my ($self) = @_;
    my $home = Cwd::cwd;
    my $dir = $self->src_dir;
    my @dirs;
    while (1) {
        $dir = Cwd::abs_path($dir);
        chdir $dir or die "'$dir' does not exist";
        die "$dir is not a directory" unless -d $dir;
        my $conf_file = 
            -f 'pkg.conf' ? 'pkg.conf' : ''
            or die "$dir contains no pkg.conf file";
        unshift @dirs, $dir;
        my $conf = YAML::XS::LoadFile($conf_file);
        last if $conf->{pkg}{top};
        my @dir = File::Spec->splitdir($dir) or die;
        pop @dir;
        $dir = File::Spec->catdir(@dir) or die;
    }
    chdir $home or die;
    return \@dirs;
}

sub manifest_builder {
    my ($self) = @_;
    my $manifest = {};
    $self->tree_walker(manifest => sub {
        my ($name, $path) = @_;
        $manifest->{$name} = Cwd::abs_path($path);
    });
    return $manifest;
}

sub stash_builder {
    my ($self) = @_;
    my $stash = {};
    $self->tree_walker(stash => sub {
        my $hash = YAML::XS::LoadFile('pkg.conf') || {};
        $author_name_hack ||= $hash->{author}{name};
        $stash = Hash::Merge::merge($hash, $stash);
    });
    $stash->{date}{year} = (localtime)[5] + 1900;
    $stash->{date}{time} = do { $_ = `date`; chomp; $_ };
    $stash = Hash::Merge::merge(
        $self->cli_args_hash, $stash,
    );
    my @keys = keys %$stash;
    for my $k (@keys) {
        next unless $k =~ /\./;
        $stash = Hash::Merge::merge(
            $self->hashlet($k, delete $stash->{$k}),
            $stash,
        );
    }

    $self->{stash} = $stash;
    if (my $rules = delete $stash->{pkg}{rules}) {
        for my $rule (@$rules) {
            $self->apply($rule);
        }
    }
    $stash = $self->{stash};

    return $stash;
}

sub apply {
    my ($self, $rule) = @_;
    $rule;
    my $method = $self->get_method($rule);
    die "$method rule not supported"
        unless $self->can($method);
    return $self->$method($rule);
}

sub get_method {
    my ($self, $args) = @_;
    return "apply_" . shift @$args;
}

sub get_arg {
    my ($self, $args) = @_;
    my $arg = shift @$args;
    return ref($arg)
    ? $self->apply($arg)
    : $arg;
}

sub set_value {
    my ($self, $key, $value) = @_;
    my $hash = $self->hashlet($key, $value);
    my $stash = $self->{stash};
    delete $stash->{$key};
    $self->{stash} = Hash::Merge::merge(
        $hash,
        $stash,
    );
    return $value;
}

sub apply_get {
    my ($self, $args) = @_;
    my $key = $self->get_arg($args);
    return $self->lookup($key);
}

sub apply_init {
    my ($self, $args) = @_;
    my $name = $self->get_arg($args);
    my $value = $self->lookup($name);
    return $value if defined $value;
    $value = $self->get_arg($args);
    return unless defined $value;
    return $self->set_value($name, $value);
}

sub apply_replace {
    my ($self, $args) = @_;
    my $val = $self->get_arg($args);
    my $pat = $self->get_arg($args);
    my $rep = $self->get_arg($args);
    return unless defined $val;
    $val =~ s/$pat/$rep/g;
    return $val;
}

sub lookup {
    my ($self, $k, $v) = @_;
    $v ||= $self->{stash};
    while ($k =~ s/(.*?)\.//) {
        $v = $v->{$1};
    }
    return unless defined $v and ref($v) eq 'HASH';
    return $v->{$k};
}

sub hashlet {
    my ($self, $k, $v) = @_;
    my $h = {};
    my $p = $h;
    while ($k =~ s/(.*?)\.//) {
        $p = $p->{$1} = {};
    }
    $p->{$k} = $v;
    return $h;
}

sub cli_args_hash {
    my ($self) = @_;
    my $hash = {};
    my $args = $self->cli_args;
    for my $arg (@$args) {
        $arg =~ /^--([\w\.]+)(?:=(.*))?$/ or next;
        my ($k, $v) = ($1, $2);
        $v = 1 if not defined $v;
        if (exists $hash->{$k}) {
            $hash->{$k} = [$hash->{$k}]
                unless ref $hash->{$k} eq 'ARRAY';
            push @{$hash->{$k}}, $2;
        }
        else {
            $hash->{$1} = $2;
        }
    }
    return $hash;
}

sub tree_walker {
    my ($self, $type, $callback) = @_;
    my $home = Cwd::cwd;
    my $dirs = $self->dirs;
    for (my $i = 0; $i < @$dirs; $i++) {
        my $dir = $dirs->[$i];
        chdir $dir;
        File::Find::find(sub {
            if (-f 'pkg.conf' and $File::Find::dir ne $File::Find::topdir) {
                $File::Find::prune = 1;
                return;
            }
            if ($i == 0) {
                if ($type eq 'stash') {
                    $callback->();
                }
                $File::Find::prune = 1;
                return;
            }
            if ($File::Find::dir =~ /\.git/) {
                $File::Find::prune = 1;
                return;
            }
            if ($_ eq 'pkg.conf') {
                if ($type eq 'stash') {
                    $callback->();
                }
                return;
            }
            return if /^\./;
            return if -d;
            if ($type eq 'manifest') {
                $callback->($File::Find::name, $_);
            }
        }, '.');
    }
    chdir $home;
}

1;
