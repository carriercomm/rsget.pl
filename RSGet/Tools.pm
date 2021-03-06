package RSGet::Tools;
# This file is an integral part of rsget.pl downloader.
#
# 2009-2010 (c) Przemysław Iskra <sparky@pld-linux.org>
#		This program is free software,
# you may distribute it under GPL v2 or newer.

use strict;
use warnings;
use vars qw(@ISA @EXPORT @EXPORT_OK);

sub set_rev($);
set_rev qq$Id$;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(set_rev s2string bignum de_ml hadd hprint p isotime require_prog
	irand randid jstime def_settings setting verbose
	data_file dump_to_file randomize);
@EXPORT_OK = qw();

our %revisions;

sub set_rev($)
{
	my @id = split /\s+/, shift;
	my $pm = $id[1];
	my $rev = $id[2];
	$pm =~ s/\.pm$//;
	$revisions{ $pm } = 0 | $rev;
}

sub s2string($)
{
	my $s = shift;
	my $minutes = int( $s / 60 );
	my $seconds = $s % 60;

	if ( $minutes >= 60 ) {
		my $hours = int( $minutes / 60 );
		$minutes %= 60;
		return sprintf '%d:%.2d:%.2d', $hours, $minutes, $seconds;
	} else {
		return sprintf '%d:%.2d', $minutes, $seconds;
	}
}

sub bignum($)
{
	local $_ = shift;
	return $_ if /[^\d]/;
	s/(..?.?)(?=(...)+$)/$1_/g;
	return $_;
}

sub hadd(\%@)
{
	my $h = shift;
	my %new = @_;
	@$h{ keys %new } = values %new;
}


sub p($)
{
	require RSGet::Line;
	new RSGet::Line( "INFO: ", shift );
}

sub hprint(%)
{
	my $h = shift;
	foreach my $k ( keys %$h ) {
		my $v = $h->{ $k };
		if ( not defined $v ) {
			$v = "undef";
		} elsif ( $v =~ /^\d+$/ ) {
		} else {
			$v = '"' . $v . '"';
		}
		p "$k => $v";
	}
}

sub randomize
{
	# not really good, but works
	return sort { 0.5 <=> rand } @_;
}

sub irand($;$)
{
	my $arg = shift;
	return int rand $arg unless @_;

	return int ( $arg + rand ( (shift) - $arg ) );
}

sub randid()
{
	return join "", map { sprintf "%.4x", int rand 1 << 16 } (0..7);
}

sub isotime()
{
	my @l = localtime;
	return sprintf "%d-%.2d-%.2d %2d:%.2d:%.2d", $l[5] + 1900, $l[4] + 1, @l[(3,2,1,0)];
}

sub jstime()
{
	return time * 1000 + irand 1000;
}

sub de_ml
{
	local $_ = shift;
	s/&le;/</g;
	s/&ge;/>/g;
	s/&quot;/"/g;
	s/&#(\d+);/chr $1/eg;
	s/&amp;/&/g;
	return $_;
}

sub require_prog
{
	my $prog = shift;
	foreach my $dir ( split /:+/, $ENV{PATH} ) {
		my $full = "$dir/$prog";
		return $full if -x $full;
	}
	return undef;
}

sub data_file
{
	my $file = shift;
	my $f = "$main::local_path/data/$file";
	return $f if -r $f;
	$f = "$main::install_path/data/$file";
	return $f if -r $f;
	return undef;
}

sub def_settings
{
	my %s = @_;
	my %options = (
		desc => "Setting description.",
		default => "Default value.",
		allowed => "RegExp that defines allowed values.",
		dynamic => "May be changed after start.",
		type => "Type of the setting.",
		user => "May be modified by user.",
	);
	foreach my $k ( keys %s ) {
		my $v = $s{ $k };
		if ( ref $v ne "HASH" ) {
			die "Setting '$k' is not a HASH\n";
		}
		if ( not $v->{desc} ) {
			die "Setting '$k' is missing description\n";
		}
		foreach ( keys %$v ) {
			die "Setting '$k' has unknown option: $_\n"
				unless exists $options{ $_ };
		}
		$main::def_settings{ $k } = $v;
	}
}

sub setting
{
	my $name = shift;
	die "Setting '$name' is not defined\n" unless exists $main::def_settings{ $name };
	return $main::settings{ $name }->[0] if exists $main::settings{ $name };
	return $main::def_settings{ $name }->{default};
}

sub verbose
{
	my $min = shift;
	return 1 if setting( "debug" );
	return 1 if setting( "verbose" ) >= $min;
	return 0;
}

sub dump_to_file
{
	my $data = shift;
	my $ext = shift || "txt";
	my $i = 0;
	my $file;
	do {
		$i++;
		$file = "dump.$i.$ext";
	} while ( -e $file );

	open my $f_out, '>', $file;
	print $f_out $data;
	close $f_out;

	warn "data dumped to file: $file\n";
}

1;

# vim: ts=4:sw=4
