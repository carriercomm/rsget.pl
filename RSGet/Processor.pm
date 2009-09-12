package RSGet::Processor;

use strict;
use warnings;
use RSGet::Tools;

my $options = "name|short|uri|slots|cookie|status";
my $parts = "pre|start|perl";

my $processed = "";
sub pr(@)
{
	my $line = join "", @_;
	$processed .= $line;
	return length $line;
}

my $is_sub = 0;
sub p_sub
{
	my $sub = shift;
	pr "sub $sub {\n";
	pr "\tmy \$self = shift;\n";
	foreach ( @_ ) {
		pr "\t$_;\n";
	}
	$is_sub++;
}
sub p_subend
{
	return unless $is_sub;
	$is_sub--;
	pr "\treturn \${self}->error( 'file is a html page' );\n}\n";
}

my $space;
sub p_ret
{
	my $ret = shift;
	my @opts = @_;
	pr $space . "return \${self}->${ret}( ";
	pr join( ", ", @opts ) . ", " if @opts;
}

sub p_line
{
	s/\$-{/\$self->{/g;
	pr $_ . "\n";
}


sub read_file
{
	my $class = shift;
	my $file = shift;

	open F_IN, '<', $file;

	my %opts;
	my %parts = (
		pre => [],
		start => [],
		perl => [],
	);
	my $part = undef;
	while ( <F_IN> ) {
		chomp;
		next unless length;
		next if /^\s*#/;

		if ( $part ) {
			unless ( /^\S+/ ) {
				push @{$parts{$part}}, $_;
				next;
			}
			if ( $part eq "perl" ) {
				push @{$parts{perl}}, $_, <F_IN>;
				last;
			} elsif ( $part eq "start" and /^stage_.*?:/ ) {
				push @{$parts{start}}, $_;
				next;
			}
			$part = undef;
		}

		if ( /^($parts)\s*:/ ) {
			$part = $1;
		} elsif ( /^($options)\s*:\s+(.*)$/ ) {
			$opts{$1} = $2;
		}
	}

	close F_IN;
	unless ( scalar @{$parts{start}} ) {
		p "Can't find 'start:'\n";
		return undef;
	}
	foreach ( qw(name short uri) ) {
		next if $opts{$_};
		p "Can't find '$_:'\n";
		return undef;
	}
	$file =~ m{.*/(.*?)$};
	my $fname = $1;
	if ( $fname ne $opts{name} ) {
		p "Name field: '$opts{name}' differs from file name: '$fname'\n";
		return undef;
	}
	if ( $opts{status} and $opts{status} !~ /^OK(\s+.*)?$/ ) {
		p "Marked as '$opts{status}'\n";
		return undef;
	}

	$processed = "";
	$space = "";
	$is_sub = 0;

	$opts{uri} = eval $opts{uri};
	$opts{class} = ${class};
	$opts{pkg} = "${class}::$opts{name}";

	pr "package $opts{pkg};\n\n";
	pr <<'EOF';
	use strict;
	use warnings;
	use RSGet::Get;
	use RSGet::Tools;

	BEGIN {
		our @ISA;
		@ISA = qw(RSGet::Get);
	}
EOF

	pr join "\n", @{$parts{pre}}, "\n";

	my $stage = 0;
	p_sub( "stage0" );
	my @machine = @{$parts{start}};
	while ( $_ = shift @machine ) {
		s/^(\s+)//;
		$space = $1;

		if ( s/^GET\s*\(// ) {
			my $next_stage = "stage" . ++$stage;
			my @skip;
			push @skip, $_;
			until ( /;\s*$/ ) {
				$_ = shift @machine;
				push @skip, $_;
			}
			if ( $machine[0] =~ s/^(stage_.*?):\s*$// ) {
				$next_stage = $1;
				shift @machine;
			}
			p_ret( "get", "\\&$next_stage" );
			foreach ( @skip ) {
				p_line();
			}
			p_subend();
			p_sub( $next_stage );
		} elsif ( s/^GET_NEXT\s*\(\s*(.*?)\s*,// ) {
			my $next_stage = $1;
			p_ret( "get", "\\&$1" );
			p_line();
		} elsif ( s/^ERROR\s*\(// ) {
			p_ret( "error" );
			p_line();
		} elsif ( s/^INFO\s*\(// ) {
			pr $space . 'return "info" if $self->info( ';
			p_line();
		} elsif ( s/^SEARCH\s*\(// ) {
			pr $space . 'return if $self->search( ';
			p_line();
		} elsif ( s/^WAIT\s*\(// ) {
			my $next_stage = "stage" . ++$stage;
			my @skip;
			push @skip, $_;
			until ( /;\s*$/ ) {
				$_ = shift @machine;
				push @skip, $_;
			}
			if ( $machine[0] =~ s/^(stage_.*?):\s*$// ) {
				$next_stage = $1;
				shift @machine;
			}
			p_ret( "wait", "\\&$next_stage" );
			foreach ( @skip ) {
				p_line();
			}
			p_subend();
			p_sub( $next_stage );
		} elsif ( s/^WAIT_NEXT\s*\(\s*(.*?)\s*,// ) {
			my $next_stage = $1;
			p_ret( "wait", "\\&$next_stage" );
			p_line();
		} elsif ( s/^RESTART\s*\(\s*// ) {
			p_ret( "restart" );
			p_line();
		} elsif ( s/^DOWNLOAD\s*\(\s*// ) {
			p_ret( "download" );
			p_line();
			until ( /;\s*$/ ) {
				$_ = shift @machine;
				p_line();
			}
			p_subend();
			p_sub( "stage_is_html" );
		} elsif ( s/^LINK\s*\(\s*// ) {
			p_ret( "link" );
			p_line();
			until ( /;\s*$/ ) {
				$_ = shift @machine;
				p_line();
			}
			p_subend();
		} elsif ( s/^MULTI\s*\(// ) {
			p_ret( "multi" );
			p_line();
		} elsif ( s/^PRINT\s*\(// ) {
			pr $space . '$self->print(';
			p_line();
		} elsif ( s/^LOG\s*\(// ) {
			pr $space . '$self->log(';
			p_line();
		} elsif ( s/^!\s+// ) {
			my $line = quotemeta $_;
			pr $space . 'return $self->problem( "'. $line .'" ) unless ';
			p_line();
		} else {
			pr $space;
			p_line();
		}
	}
	p_subend();

	pr @{$parts{perl}};
	pr "1;";

	my $ret = eval $processed;

	if ( $@ ) {
		p "Error(s): $@\n";
		return undef unless $settings{logging} > 0;
		my $err = $@;
		return undef unless $err =~ /line \d+/;
		my @p = split /\n/, $processed;
		for ( my $i = 0; $i < scalar @p; $i++ ) {
			my $n = $i + 1;
			p sprintf "%s%4d: %s\n",
				($err =~ /line $n[^\d]/ ? "!" : " "),
				$n,
				$p[ $i ];
		}
		return undef;
	}

	return $opts{pkg} => \%opts if $ret and $ret == 1;
	return ();
}

1;
# vim:ts=4:sw=4