package RSGet::Tools;

use strict;
use warnings;
use vars qw(@ISA @EXPORT @EXPORT_OK);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(s2string bignum de_ml hadd hprint p isotime require_prog
	dump_to_file randomize %getters %settings);
@EXPORT_OK = qw();

our %settings;
our %getters;

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

sub hadd(%@)
{
	my $h = shift;
	my %new = @_;
	foreach ( keys %new ) {
		$h->{$_} = $new{$_};
	}
}


sub p($)
{
	require RSGet::Line;
	new RSGet::Line( "INFO: ", shift );
}

sub hprint(%)
{
	my $h = shift;
	foreach ( keys %$h ) {
		p "$_ => $h->{$_}";
	}
}

sub randomize
{
	# not really good, but works
	return sort { 0.5 <=> rand } @_;
}


sub isotime()
{
	my @l = localtime;
	return sprintf "%d-%.2d-%.2d %2d:%.2d:%.2d", $l[5] + 1900, $l[4] + 1, @l[(3,2,1,0)];
}

sub de_ml
{
	local $_ = shift;
	s/&le;/</g;
	s/&ge;/>/g;
	s/&quot;/"/g;
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
# vim:ts=4:sw=4