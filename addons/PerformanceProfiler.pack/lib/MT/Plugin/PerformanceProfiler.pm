package MT::Plugin::PerformanceProfiler;

use v5.10;
use strict;
use warnings;
use utf8;

use Digest::SHA1 qw(sha1_hex);
use File::Copy qw(move);
use File::Basename qw(basename);
use File::Spec;
use File::Temp;
use JSON;
use Time::HiRes qw(gettimeofday tv_interval);
use MT::Plugin::PerformanceProfiler::KYTProfLogger;
use MT::Plugin::PerformanceProfiler::Guard;

use constant FILE_PREFIX => 'b-';

our ( $current_tmp, $current_file, $current_metadata, $current_start );
our ( $freq, $counter );
our (%profilers);

our $json_encoder = JSON->new->utf8;

sub path {
    state $path = MT->config->PerformanceProfilerPath;
    return $path;
}

sub enabled {
    return !!path();
}

sub tmp_file_name {
    my $key = shift;
    File::Spec->catfile( $current_tmp, sprintf( $current_file, $key ) ),;
}

sub rename_tmp_file_to_out_file {
    my $key = shift;
    my $tmp = tmp_file_name($key);

    my $dir = File::Spec->catfile( path(), sprintf( '%02d', (localtime)[2] ) );    # hour
    mkdir $dir unless -d $dir;

    my $out = File::Spec->catfile( $dir, sprintf( $current_file, $key ) );
    move( $tmp, $out )
        or unlink $tmp;
}

sub enable_profile {
    my ( $file, $metadata ) = @_;

    state $mt_temp_dir = MT->config->TempDir;
    $current_tmp      = File::Temp->newdir( DIR => $mt_temp_dir );
    $current_file     = $file;
    $current_metadata = $metadata;
    $current_start    = [gettimeofday];

    if ( $profilers{KYTProf} ) {

        # XXX: force re-initialize $Devel::KYTProf::Profiler::DBI::_TRACER
        Devel::KYTProf::Profiler::DBI->apply;
        Devel::KYTProf->logger(
            MT::Plugin::PerformanceProfiler::KYTProfLogger->new(
                tmp_file_name('kyt'), $json_encoder
            )
        );
    }

    if ( $profilers{NYTProf} ) {
        DB::enable_profile( tmp_file_name('nyt') );
    }
}

sub finish_profile_kytprof {

    # FIXME: We want to release DBIx::Tracer in an implementation-independent way
    return unless $Devel::KYTProf::Profiler::DBI::_TRACER;

    Devel::KYTProf->mute($_) for qw(DBI DBI::st DBI::db);
    undef $Devel::KYTProf::Profiler::DBI::_TRACER;
    Devel::KYTProf->_orig_code( {} );
    Devel::KYTProf->_prof_code( {} );
}

sub finish_profile {
    my ($opts) = @_;
    $opts ||= {};

    return unless $current_file;

    $current_metadata->{runtime} = tv_interval($current_start);

    if ( $profilers{NYTProf} ) {
        DB::finish_profile();

        if ( !$opts->{cancel} ) {

            # append meta data
            my $file = tmp_file_name('nyt');
            open my $fh, '>>', $file;
            print {$fh} '# ' . $json_encoder->encode($current_metadata) . "\n";
            close $fh;

            rename_tmp_file_to_out_file('nyt');
        }
    }

    if ( $profilers{KYTProf} ) {
        finish_profile_kytprof();

        if ( !$opts->{cancel} ) {

            # append meta data
            Devel::KYTProf->logger->print( $json_encoder->encode($current_metadata) . "\n" );
            Devel::KYTProf->logger(undef);    # release current logger in order to close file handle

            rename_tmp_file_to_out_file('kyt');
        }
    }

    undef $current_tmp;
    undef $current_file;
}

sub cancel_profile {
    my $file = $current_file
        or return;

    finish_profile( { cancel => 1 } );

    unlink sprintf( $file, 'nyt' ) if $profilers{NYTProf};
    unlink sprintf( $file, 'kyt' ) if $profilers{KYTProf};
}

sub init_app {
    my $dir = path()
        or return;

    $freq = MT->config->PerformanceProfilerFrequency
        or return;
    $counter = int( rand($freq) );

    %profilers = map { $_ => 1 }
        split( /\s*,\s*/, MT->config('PerformanceProfilerProfilers') );

    if ( $profilers{KYTProf} ) {
        require Devel::KYTProf;
        Devel::KYTProf->apply_prof('DBI');
        Devel::KYTProf->namespace_regex('MT::Template');
        finish_profile_kytprof;
    }

    if ( $profilers{NYTProf} ) {
        my @opts = qw( sigexit=int savesrc=0 start=no );
        $ENV{"NYTPROF"} = join ":", @opts;
        require Devel::NYTProf;
    }

    mkdir $dir unless -d $dir;

    1;
}

sub _build_file_filter {
    my ( $cb, %param ) = @_;

    return unless enabled();

    if ( $freq > 1 ) {
        $counter = ( $counter + 1 ) % $freq;
        return unless $counter == 0;
    }

    $param{context}->stash( 'performance_profiler_guard',
        MT::Plugin::PerformanceProfiler::Guard->new( \&cancel_profile ) );

    my $filename = sha1_hex( $param{File} );

    enable_profile(
        FILE_PREFIX . '%s-' . $filename,
        {   version         => $MT::VERSION,
            product_version => $MT::PRODUCT_VERSION,
            file            => sha1_hex( $param{File} ),
            archive_type    => $param{ArchiveType},
        },
    );
}

sub build_file_filter {
    _build_file_filter(@_);
    1;    # always returns true
}

sub build_page {
    my ($cb) = @_;

    return 1 unless enabled();
    finish_profile();

    1;
}

1;
