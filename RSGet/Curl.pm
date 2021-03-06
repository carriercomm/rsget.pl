package RSGet::Curl;
# This file is an integral part of rsget.pl downloader.
#
# 2009-2010 (c) Przemysław Iskra <sparky@pld-linux.org>
#		This program is free software,
# you may distribute it under GPL v2 or newer.

use strict;
use warnings;
use RSGet::Tools;
use RSGet::Line;
use RSGet::Hook;
BEGIN {
	eval { require Net::Curl::Compat; };
	if ( $@ ) {
		warn "\nERROR::Could not load Net::Curl::Compat -- " .
			"will use WWW::Curl instead\n";
		warn "NOTE: future rsget.pl versions will require Net::Curl to run,\n" .
			"so make sure it is available in your operating system before " .
			"that happens.\n\n";
	} else {
		print "Using Net::Curl, woohoo !\n";
	}
}
use WWW::Curl::Easy 4.00;
use WWW::Curl::Multi;
use URI::Escape;
use MIME::Base64;
use File::Copy ();
use File::Path;
use Fcntl qw(SEEK_SET);
set_rev qq$Id$;

def_settings(
	backup => {
		desc => "Make backups if downloaded file exists.",
		default => "done,scratch",
		allowed => qr/(no|(done|continue|scratch)(?:,(done|continue|scratch))*)/,
		dynamic => {
			'done,continue,scratch' => "Always.",
			done => "Only if it would replace file in outdir.",
			'continue,scratch' => "Only if it whould replace file in workdir.",
			no => "Never.",
		},
		user => 1,
	},
	backup_suf => {
		desc => "Rename backup files with specified suffix. " .
			"If none defined -N will be added to file name, without disrupting file extension.",
		allowed => qr/\S*/,
		type => "STRING",
		user => 1,
	},
	outdir => {
		desc => "Output directory; where finished files are moved to.",
		default => '.',
		type => "PATH",
		user => 1,
	},
	workdir => {
		desc => "Work directory; where unfinished files are stored.",
		default => '.',
		type => "PATH",
		user => 1,
	},
	postdownload => {
		desc => "Command executed after finishing download.",
		type => "COMMAND",
	},
);


my $curl_multi;

my $curl_headers = [
	'User-Agent: Mozilla/5.0 (Windows; U; Windows NT 5.1; en-US; rv:1.9.0.10) Gecko/2009042316 Firefox/3.0.10',
	'Accept: text/xml,application/xml,application/xhtml+xml,text/html;q=0.9,text/plain;q=0.8,image/png,*/*;q=0.5',
	'Accept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.7',
	'Accept-Language: en-us,en;q=0.5',
	];

# X-Forwarded-For: XX.XX.XXX.XXX
# Cache-Control: bypass-client=XX.XX.XX.XXX

my %active_curl;

{
	my %proxytype = (
		http	=> 0,	# CURLPROXY_HTTP
		http10	=> 1,	# CURLPROXY_HTTP_1_0
		socks4	=> 4,	# CURLPROXY_SOCKS4
		socks4a	=> 6,	# CURLPROXY_SOCKS4a
		socks5	=> 5,	# CURLPROXY_SOCKS5
		socks	=> 5,	# CURLPROXY_SOCKS5
		socks5host => 7, # CURLPROXY_SOCKS5_HOSTNAME
	);

	sub set_outif
	{
		my $curl = shift;
		my $outif = shift;
		foreach my $if ( split /;+/, $outif ) {
			if ( $if =~ /^([a-z0-9]+)=(\S+)(:(\d+))?$/ ) {
				my ($tn, $host, $port) = ($1, $2, $4);
				if ( exists $proxytype{ $tn } ) {
					$curl->setopt( CURLOPT_PROXYTYPE, $proxytype{ $tn } );
					$curl->setopt( CURLOPT_PROXY, $host );
					$curl->setopt( CURLOPT_PROXYPORT, $port )
						if $port;
				} else {
					warn "Unrecognized proxy type '$tn' in '$outif'\n";
				}
			} elsif ( $if =~ /^\S+$/ ) {
				$curl->setopt( CURLOPT_INTERFACE, $if );
			} else {
				warn "Unrecognized interface string '$if' in '$outif'\n";
			}
		}
	}
}

sub init
{
	$curl_multi = new WWW::Curl::Multi;

	if ( verbose( 1 ) ) {
		p "Using paths:";
		require Cwd;
		foreach ( qw(workdir outdir) ) {
			my $dir = Cwd::abs_path( setting( $_ ) );
			my $mkdir = "";
			$mkdir = " (will be created)" unless -d $dir;
			p "  $_ => $dir$mkdir";
		}
	}
}

sub new
{
	my $uri = shift;
	my $get_obj = shift;
	my %opts = @_;

	my $curl = new WWW::Curl::Easy;

	my $id = 1;
	++$id while exists $active_curl{ $id };

	my $supercurl = {
		curl => $curl,
		id => $id,
		get_obj => $get_obj,
		got => 0,
		head => "",
		body => "",
	};

	$curl->setopt( CURLOPT_PRIVATE, $id );

	set_outif( $curl, $get_obj->{_outif} ) if $get_obj->{_outif};

	if ( defined $get_obj->{_cookie} ) {
		$curl->setopt( CURLOPT_COOKIEJAR, $get_obj->{_cookie} );
		$curl->setopt( CURLOPT_COOKIEFILE, $get_obj->{_cookie} );
	}
	$curl->setopt( CURLOPT_HEADERFUNCTION, \&body_scalar );
	$curl->setopt( CURLOPT_WRITEHEADER, \$supercurl->{head} );
	$curl->setopt( CURLOPT_MAXREDIRS, 10 );
	$curl->setopt( CURLOPT_FOLLOWLOCATION, 1 );
	if ( $opts{headers} ) {
		my @h = @$curl_headers;
		push @h, @{ $opts{headers} };
		$curl->setopt( CURLOPT_HTTPHEADER, \@h );
	} else {
		$curl->setopt( CURLOPT_HTTPHEADER, $curl_headers );
	}
	$curl->setopt( CURLOPT_URL, $uri );
	$curl->setopt( CURLOPT_REFERER, $get_obj->{_referer} )
		if defined $get_obj->{_referer};
	$curl->setopt( CURLOPT_ENCODING, 'gzip,deflate' );
	$curl->setopt( CURLOPT_CONNECTTIMEOUT, 20 );
	$curl->setopt( CURLOPT_SSL_VERIFYPEER, 0 );

	if ( $opts{post} ) {
		my $post = $opts{post};
		$curl->setopt( CURLOPT_POST, 1 );
		if ( ref $post and ref $post eq "HASH" ) {
			$post = join "&",
				map { uri_escape( $_ ) . "=" . uri_escape( $post->{$_} ) }
				sort keys %$post;
		}
		$get_obj->log( "POST( $uri ): $post\n" ) if verbose( 3 );
		$curl->setopt( CURLOPT_POSTFIELDS, $post );
		$curl->setopt( CURLOPT_POSTFIELDSIZE, length $post );
	} else {
		$get_obj->log( "GET( $uri )\n" ) if verbose( 4 );
	}

	if ( $opts{headonly} ) {
		$curl->setopt( CURLOPT_NOBODY, 1 );
		$supercurl->{headonly} = 1;
	} elsif ( $opts{save} ) {
		$curl->setopt( CURLOPT_WRITEFUNCTION, \&body_file );
		$curl->setopt( CURLOPT_WRITEDATA, $supercurl );

		$supercurl->{force_size} = $opts{fsize} if $opts{fsize};
		$supercurl->{force_name} = $opts{fname} if $opts{fname};

		# if file exists try to continue
		my $fn = $get_obj->{_opts}->{fname};
		if ( $fn ) {
			my $fp = filepath( setting("workdir"), $get_obj->{_opts}->{dir}, $fn );
			if ( -r $fp ) {
				my $got = (stat(_))[7];
				#p "File '$fn' already exists, trying to continue at $got";
				$curl->setopt( CURLOPT_RANGE, "$got-" );

				$get_obj->log( "trying to continue at $got\n" ) if verbose( 4 );
				$supercurl->{continue_at} = $got;
				$supercurl->{fname} = $fn;
				$supercurl->{filepath} = $fp
			}
		}

		my $fs = $get_obj->{_opts}->{fsize};
		$supercurl->{fsize} = $fs if $fs;

		delete $get_obj->{is_html};
	} else {
		$get_obj->{is_html} = 1;
		$curl->setopt( CURLOPT_WRITEFUNCTION, \&body_scalar );
		$curl->setopt( CURLOPT_WRITEDATA, \$supercurl->{body} );
	}
	if ( my $curlopts = $opts{curlopts} ) {
		while ( my ( $key, $val ) = each %$curlopts ) {
			$curl->setopt( $key, $val );
		}
	}

	if ( $opts{keep_referer} or $opts{keep_ref} ) {
		$supercurl->{keep_referer} = 1;
	}

	$active_curl{ $id } = $supercurl;
	$curl_multi->add_handle( $curl );
}

sub file_backup
{
	my $fn = shift;
	my $type = shift;
	return undef unless setting("backup") =~ /$type/;
	return undef unless -r $fn;

	if ( my $s = setting("backup_suf") ) {
		my $i = 1;
		++$i while -r $fn . $s . $i;
		return $fn . $s . $i;
	}

	my $ext = "";
	$ext = $1 if $fn =~ s/(\..{3,5})$//;
	my $i = 1;
	++$i while -r "$fn-$i$ext";

	return "$fn-$i$ext";
}

sub content_filename
{
	# TODO: actually read rfc2183 and rfc2184
	local $_ = shift;

	s/\s*;?\s+$//; # remove at least last \r
	my $src = $_;
	if ( s/^\s*=\?(.+?)\?(.*)\?=\s*/$2/ ) {
		warn "C-D: Unknown filename encoding: $1, at $src\n"
			if uc $1 ne "UTF-8" and verbose( 1 );
	}
	unless ( s/^\s*attachment\s*//i ) {
		warn "Not an attachment in C-D: '$src'\n" if verbose( 1 );
		return;
	}
	unless ( s/^;(.*?\s+)?filename//i ) {
		warn "No filename in C-D: '$src'\n" if verbose( 1 );
		return;
	}
	if ( s/^\*=(.+?)('.*?')// ) {
		warn "C-D: Unknown filename encoding: $1 $2, at $src\n"
			if uc $1 ne "UTF-8" and verbose( 1 );
		s/\s+.*//;
		return $_;
	}
	return unless s/^\s*=\s*//;
	if ( s/^"// ) {
		unless ( s/".*// ) {
			warn "C-D: Broken filename: $src\n"
				if verbose( 1 );
			return;
		}
	} elsif ( m/=\?(.*?)\?B\?(.*?)\?=/ ) {
		# described in rfc2047
		warn "C-D: Unsupported filename encoding: $1, at $src\n"
			if uc $1 ne "UTF-8" and verbose( 1 );
		$_ = decode_base64( $2 );
	} else {
		s/[;\s].*//;
	}
	p "C-D filename is: $_\n" if verbose( 2 );
	return $_;
}

sub file_init
{
	my $supercurl = shift;
	my $curl = $supercurl->{curl};
	my $get_obj = $supercurl->{get_obj};
	my $time = time;

	hadd %$supercurl,
		time_start => $time,
		time_stamp => [ $time, 0, $time, 0, $time, 0 ],
		size_start => 0,
		size_got => 0;

	{
		my $mime = $curl->getinfo( CURLINFO_CONTENT_TYPE ) || "unknown";
		if ( $mime =~ m#^text/html# ) {
			$get_obj->{is_html} = 1;
			$supercurl->{size_total} = 0;
			return;
		}
	}

	if ( my $f_len = $curl->getinfo( CURLINFO_CONTENT_LENGTH_DOWNLOAD ) ) {
		$supercurl->{size_total} = $f_len;
	}
	if ( ( $supercurl->{size_total} || 0 ) <= 0 and $supercurl->{force_size} ) {
		$supercurl->{size_total} = $supercurl->{force_size};
	}

	$get_obj->{_quota}->update( $supercurl->{size_total} );

	$get_obj->dump( $supercurl->{head}, "head" ) if verbose( 5 );
	my $fname;
	if ( $supercurl->{force_name} ) {
		$fname = $supercurl->{force_name};
	} elsif ( $supercurl->{head} =~ /^Content-Disposition:(.+?)$/mi ) {
		my $cf = content_filename( $1 );
		$fname = de_ml( uri_unescape( $cf ) ) if defined $cf and length $cf;
	}
	unless ( $fname ) {
		my $eurl = $curl->getinfo( CURLINFO_EFFECTIVE_URL );
		$eurl =~ s#^.*/##;
		$eurl =~ s/\?.*$//;
		$fname = de_ml( uri_unescape( $eurl ) );
	}

	{
		local $SIG{__DIE__} = 'DEFAULT';
		eval {
			utf8::decode( $fname );
			utf8::encode( $fname );
		};
		if ( $@ ) {
			# as a fallback kill all non-ascii chars
			$fname =~ s/([^[:ascii:]])/sprintf "<%.2x>", ord($1)/eg;
		}
	}

	if ( my $fn = $supercurl->{fname} ) {
		if ( $fname ne $fn ) {
			$get_obj->log( "WARNING: Name mismatch, shoud be '$fname'" );
		}
		$fname = $supercurl->{fname};

		my $start;
		if ( $supercurl->{head} =~ m{^Content-Range:\s*bytes\s*(\d+)-(\d+)(/(\d+))?\s*$}im ) {
			$start = +$1;
			$supercurl->{size_total} = +$4 if $3;

			$get_obj->log( "ERROR: Size mismatch: $supercurl->{fsize} != $supercurl->{size_total}" )
				if $supercurl->{fsize} != $supercurl->{size_total};
		} elsif ( $supercurl->{head} =~ m{^350\s}m ) {
			$start = $supercurl->{continue_at};
			$supercurl->{size_total} = $start + $curl->getinfo( CURLINFO_CONTENT_LENGTH_DOWNLOAD );
		}

		if ( defined $start ) {
			my $fp = $supercurl->{filepath};
			my $old = file_backup( $fp, "continue" );
			my $old_msg = "";
			if ( $old ) {
				rename $fp, $old;
				File::Copy::copy( $old, $fp )
					or die "Cannot create backup file: $!";
				$old =~ s#.*/##;
				$old_msg = ", backup saved as '$old'";
			}

			open my $f_out, '+<', $fp;
			seek $f_out, $start, SEEK_SET;
			$get_obj->log( "Continuing at " . bignum( $start ) . $old_msg );

			hadd %$supercurl,
				file => $f_out,
				size_start => $start,
				size_got => $start,
				time_stamp => [ $time, $start, $time, $start, $time, $start ];

			$get_obj->started_download( fname => $supercurl->{fname}, fsize => $supercurl->{size_total} );
			return;
		}
	} else {
		$supercurl->{fname} = $fname;
	}

	$get_obj->started_download( fname => $supercurl->{fname}, fsize => $supercurl->{size_total} );

	{
		my $fn = $supercurl->{filepath} =
			filepath( setting("workdir"), $get_obj->{_opts}->{dir}, $supercurl->{fname} );
		my $old = file_backup( $fn, "scratch" );
		if ( $old ) {
			rename $fn, $old;
			$old =~ s#.*/##;
			$get_obj->log( "Old renamed to '$old'" );
		}
		open my $f_out, '>', $fn;
		$supercurl->{file} = $f_out;
	}
}

sub body_file
{
	my ($chunk, $supercurl) = @_;

	file_init( $supercurl ) unless exists $supercurl->{size_total};

	my $len = length $chunk;
	$supercurl->{size_got} += $len;

	if ( my $file = $supercurl->{file} ) {
		my $p = print $file $chunk;
		die "\nCannot write data: $!\n" unless $p;
	} else {
		$supercurl->{body} .= $chunk;
		if ( length $supercurl->{body} > 1 * 1024 * 1024 ) {
			warn "Tried to save large archive to memory. Aborting. (plugin may be broken)\n";
			return 0;
		}
	}

	return $len;
}

sub body_scalar
{
	my ($chunk, $scalar) = @_;
	$$scalar .= $chunk;
	if ( length $$scalar > 1 * 1024 * 1024 ) {
		warn "Tried to save large archive to memory. Aborting. (plugin may be broken)\n";
		return 0;
	}
	return length $chunk;
}

sub filepath
{
	my $outdir = shift || '.';
	my $subdir = shift;
	my $fname = shift;

	$outdir .= '/' . $subdir if $subdir;
	unless ( -d $outdir ) {
		unless ( mkpath( $outdir ) ) {
			$outdir = '.';
		}
	}
	return $outdir . '/' . $fname;
}

sub finish
{
	my $id = shift;
	my $err = shift;

	my $supercurl = $active_curl{ $id };
	delete $active_curl{ $id };

	my $curl = $supercurl->{curl};
	delete $supercurl->{curl}; # remove circular dep

	my $get_obj = $supercurl->{get_obj};
	delete $supercurl->{get_obj};

	$supercurl->{speed_end} = $curl->getinfo( CURLINFO_SPEED_DOWNLOAD );
	if ( $supercurl->{file} ) {
		close $supercurl->{file};
		$get_obj->print( "DONE " . donemsg( $supercurl ) );

		$get_obj->{_quota}->confirm( $curl->getinfo( CURLINFO_SIZE_DOWNLOAD ) );

	}

	$get_obj->linedata();

	my $eurl = $curl->getinfo( CURLINFO_EFFECTIVE_URL );
	$get_obj->{content_type} = $curl->getinfo( CURLINFO_CONTENT_TYPE );
	my $error = $curl->errbuf;
	$curl = undef; # destroy curl before destroying getter

	if ( $err ) {
		#warn "error($err): $error\n";
		$get_obj->linecolor( "red" );
		$get_obj->print( "ERROR($err): $error" ) if $err ne "aborted";
		if ( $error =~ /Couldn't bind to '|bind failed|Could not resolve host:|Connection timed out after \d+ milliseconds/ ) {
			my $if = $get_obj->{_outif};
			RSGet::Dispatch::remove_interface( $if, "Interface $if is dead" );
			$get_obj->{_abort} = "Interface $if is dead";
			$get_obj->linecolor( "red" );
		} elsif ( $error =~ /transfer closed with (\d+) bytes remaining to read/ ) {
			RSGet::Dispatch::mark_used( $get_obj );
			$get_obj->{_abort} = "PARTIAL " . donemsg( $supercurl );
			$get_obj->linecolor( "blue" );
		} elsif ( $err eq "aborted" ) {

		} else {
			$get_obj->log( "ERROR($err): $error" );
		}
		$get_obj->problem();
		return undef;
	}

	if ( $supercurl->{file} ) {
		my $outfile;
		do_rename: {
			my $infile = $supercurl->{filepath};
			$outfile = filepath( setting("outdir"), $get_obj->{_opts}->{dir}, $supercurl->{fname} );
			if ( -e $outfile ) {
				my @si = stat $infile;
				my @so = stat $outfile;
				if ( $si[0] == $so[0] and $si[1] == $so[1] ) {
					p "$infile and $outfile are the same file, not renaming"
						if verbose( 2 );
					last do_rename;
				}

				my $out_rename = file_backup( $outfile, "done" );
				rename $outfile, $out_rename if $out_rename;
				p "backing up $outfile as $out_rename" if verbose( 1 );
			}
			p "renaming $infile to $outfile" if verbose( 2 );
			$! = undef;
			rename $infile, $outfile;
			if ( $! ) {
				warn "Cannot rename $infile to $outfile ($!), unsing File::Copy instead\n"
					if verbose( 1 );
				$! = undef;
				File::Copy::move( $infile, $outfile )
					or warn "Cannot move $infile to $outfile: $!";
			}
		}

		$get_obj->{dlinfo} = sprintf 'DONE %s %s / %s',
			$supercurl->{fname},
			bignum( $supercurl->{size_got} ),
			bignum( $supercurl->{size_total} );

		if ( my $post = setting( "postdownload" ) ) {
			RSGet::Hook::call( $post,
				file => $outfile,
				name => $supercurl->{fname},
				size => $supercurl->{size_total},
				source => $get_obj->{_uri},
			);
		}
	} else {
		$get_obj->{body} = $supercurl->{ $supercurl->{headonly} ? "head" : "body" };
	}

	$get_obj->get_finish( $eurl, $supercurl->{keep_referer} || 0 );
}

sub need_run
{
	return scalar keys %active_curl;
}

sub maybe_abort
{
	my $time = time;
	my $stall_time = $time - 120;
	foreach my $id ( keys %active_curl ) {
		my $supercurl = $active_curl{ $id };
		my $get_obj = $supercurl->{get_obj};
		if ( $get_obj->{_abort} ) {
			my $curl = $supercurl->{curl};
			$curl_multi->remove_handle( $curl );
			finish( $id, "aborted" );
		}
		if ( ( $supercurl->{stalled_since} || $time ) < $stall_time ) {
			my $curl = $supercurl->{curl};
			$curl_multi->remove_handle( $curl );
			finish( $id, "timeout" );
		}
	}
}

sub perform
{
	my $running = scalar keys %active_curl;
	return unless $running;
	my $act = $curl_multi->perform();
	return if $act == $running;

	while ( my ($id, $rv) = $curl_multi->info_read() ) {
		next unless $id;

		finish( $id, $rv );
	}
}

sub update_status
{
	my $time = time;
	my $total_speed = 0;

	foreach my $supercurl ( values %active_curl ) {
		next unless exists $supercurl->{size_total};
		my ($size_got, $size_total, $time_stamp ) =
			@$supercurl{ qw(size_got size_total time_stamp) };

		my $size = bignum( $size_got ) . " / " . bignum( $size_total );
		if ( $size_total > 0 ) {
			my $per = $size_got / $size_total;
			$size .= sprintf ' [%.2f%%]', $per * 100;
			$supercurl->{get_obj}->linedata( prog => $per );
		}

		if ( $time_stamp->[4] + 30 <= $time ) {
			@$time_stamp[0..3] = @$time_stamp[2..5];
			$time_stamp->[4] = $time;
			$time_stamp->[5] = $size_got;
		}

		my $time_diff = $time - $time_stamp->[0];
		my $size_diff = $size_got - $time_stamp->[1];

		if ( $time_diff > 0 and $size_diff == 0 ) {
			$supercurl->{stalled_since} ||= $time;
			my $stime = s2string( $time - $supercurl->{stalled_since} );
			$supercurl->{get_obj}->print( "$size; STALLED $stime" );
			next;
		}

		my $s = $supercurl->{curl}->getinfo( CURLINFO_SPEED_DOWNLOAD ) / 1024;
		my $speed = sprintf "%.2f", $s;
		$total_speed += $s;

		my $eta = "";
		if ( $size_total > 0 and $time_diff > 0 and $size_diff > 0 ) {
			my $tleft = ($size_total - $size_got) * $time_diff / $size_diff;
			$eta = " " . s2string( $tleft );
			delete $supercurl->{stalled_since}
		}

		$supercurl->{get_obj}->print( "$size; ${speed}KB/s$eta" );
	}

	my $running = scalar keys %active_curl;
	RSGet::Line::status(
		'running cURL' => $running,
		'total speed' => ( sprintf '%.2fKB/s', $total_speed )
	);
	return;
}

sub donemsg
{
	my $supercurl = shift;

	my $time_diff = time() - $supercurl->{time_start};
	$time_diff = 1 unless $time_diff;
	my $eta = s2string( $time_diff );
	my $speed = sprintf "%.2f", $supercurl->{speed_end} / 1024;

	return bignum( $supercurl->{size_got} ) . "; ${speed}KB/s $eta";
}


1;

# vim: ts=4:sw=4
