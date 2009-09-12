package RSGet::Curl;

use strict;
use warnings;
use RSGet::Tools;
use RSGet::Line;
use WWW::Curl::Easy;
use WWW::Curl::Multi;
use URI::Escape;
use File::Copy;
use Fcntl qw(SEEK_SET);

my $curl_multi = new WWW::Curl::Multi;

my $curl_headers = [
	'User-Agent: Mozilla/5.0 (Windows; U; Windows NT 5.1; en-US; rv:1.9.0.10) Gecko/2009042316 Firefox/3.0.10',
	'Accept: text/xml,application/xml,application/xhtml+xml,text/html;q=0.9,text/plain;q=0.8,image/png,*/*;q=0.5',
	'Accept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.7',
	'Accept-Language: en-us,en;q=0.5',
	];

# X-Forwarded-For: XX.XX.XXX.XXX
# Cache-Control: bypass-client=XX.XX.XX.XXX

my %active_curl;

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
	$curl->setopt( CURLOPT_INTERFACE, $get_obj->{_outif} )
		if $get_obj->{_outif};

	if ( defined $get_obj->{_cookie} ) {
		$curl->setopt( CURLOPT_COOKIEJAR, $get_obj->{_cookie} );
		$curl->setopt( CURLOPT_COOKIEFILE, $get_obj->{_cookie} );
	}
	$curl->setopt( CURLOPT_HEADERFUNCTION, \&body_scalar );
	$curl->setopt( CURLOPT_WRITEHEADER, \$supercurl->{head} );
	$curl->setopt( CURLOPT_MAXREDIRS, 10 );
	$curl->setopt( CURLOPT_FOLLOWLOCATION, 1 );
	$curl->setopt( CURLOPT_HTTPHEADER, $curl_headers );
	$curl->setopt( CURLOPT_URL, $uri );
	$curl->setopt( CURLOPT_REFERER, $get_obj->{_referer} )
		if defined $get_obj->{_referer};
	$curl->setopt( CURLOPT_ENCODING, 'gzip,deflate' );
	$curl->setopt( CURLOPT_CONNECTTIMEOUT, 20 );

	if ( $opts{post} ) {
		my $post = $opts{post};
		$curl->setopt( CURLOPT_POST, 1 );
		if ( ref $post and ref $post eq "HASH" ) {
			$post = join "&",
				map { uri_escape( $_ ) . "=" . uri_escape( $post->{$_} ) }
				sort keys %$post;
		}
		$curl->setopt( CURLOPT_POSTFIELDS, $post );
	}

	if ( $opts{save} ) {
		$curl->setopt( CURLOPT_WRITEFUNCTION, \&body_file );
		$curl->setopt( CURLOPT_WRITEDATA, $supercurl );

		# if file exists try to continue
		my $fn = $get_obj->{_opts}->{fname};
		if ( $fn and -r $fn ) {
			my $got = (stat(_))[7];
			#p "File '$fn' already exists, trying to continue at $got";
			$curl->setopt( CURLOPT_RANGE, "$got-" );

			$supercurl->{fname} = $fn;
		}

		my $fs = $get_obj->{_opts}->{fsize};
		$supercurl->{fsize} = $fs if $fs;

		delete $get_obj->{is_html};
	} else {
		$get_obj->{is_html} = 1;
		$curl->setopt( CURLOPT_WRITEFUNCTION, \&body_scalar );
		$curl->setopt( CURLOPT_WRITEDATA, \$supercurl->{body} );
	}

	$active_curl{ $id } = $supercurl;
	$curl_multi->add_handle( $curl );
}

sub file_backup
{
	my $fn = shift;
	my $type = shift;
	return undef unless $settings{backup} =~ /$type/;
	return undef unless -r $fn;

	if ( my $s = $settings{backup_suf} ) {
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

sub file_init
{
	my $supercurl = shift;
	my $curl = $supercurl->{curl};
	my $time = time;

	hadd $supercurl,
		time_start => $time,
		time_stamp => [ $time, 0, $time, 0, $time, 0 ],
		size_start => 0,
		size_got => 0;

	{
		my $mime = $curl->getinfo( CURLINFO_CONTENT_TYPE );
		if ( $mime =~ m#^text/html# ) {
			$supercurl->{get_obj}->{is_html} = 1;
			$supercurl->{size_total} = 0;
			return;
		}
	}

	if ( my $f_len = $curl->getinfo( CURLINFO_CONTENT_LENGTH_DOWNLOAD ) ) {
		$supercurl->{size_total} = $f_len;
	}

	my $fname;
	if ( $supercurl->{head} =~ /^Content-Disposition:\s*attachment;\s*filename\s*=\s*"?(.*?)"?\s*$/im ) {
		$fname = de_ml( uri_unescape( $1 ) );
	} else {
		my $eurl = $curl->getinfo( CURLINFO_EFFECTIVE_URL );
		$eurl =~ s#^.*/##;
		$fname = de_ml( uri_unescape( $eurl ) );
	}

	if ( my $fn = $supercurl->{fname} ) {
		if ( $fname ne $fn ) {
			$supercurl->{get_obj}->log( "WARNING: Name mismatch, shoud be '$fname'" );
		}
		$fname = $supercurl->{fname};
		if ( $supercurl->{head} =~ m{^Content-Range:\s*bytes\s*(\d+)-(\d+)(/(\d+))?\s*$}im ) {
			my ( $start, $stop ) = ( +$1, +$2 );
			$supercurl->{size_total} = +$4 if $3;

			$supercurl->{get_obj}->log( "ERROR: Size mismatch: $supercurl->{fsize} != $supercurl->{size_total}" )
				if $supercurl->{fsize} != $supercurl->{size_total};

			my $old = file_backup( $fn, "copy" );
			my $old_msg = "";
			if ( $old ) {
				rename $fn, $old;
				copy( $old, $fn ) || die "Cannot create backup file: $!";
				$old_msg = ", backup saved as '$old'";
			}

			open my $f_out, '+<', $fn;
			seek $f_out, $start, SEEK_SET;
			$supercurl->{get_obj}->log( "Continuing at " . bignum( $start ) . $old_msg );


			hadd $supercurl,
				file => $f_out,
				size_start => $start,
				size_got => $start,
				time_stamp => [ $time, $start, $time, $start, $time, $start ];

			RSGet::FileList::update(); # to update statistics
			return;
		}
	} else {
		$supercurl->{fname} = $fname;
	}

	$supercurl->{get_obj}->set_finfo( $supercurl->{fname}, $supercurl->{size_total} );

	{
		my $fn = $supercurl->{fname};
		my $old = file_backup( $fn, "move" );
		if ( $old ) {
			$supercurl->{get_obj}->log(  "Old renamed to '$old'" );
			rename $fn, $old;
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
	}

	return $len;
}

sub body_scalar
{
	my ($chunk, $scalar) = @_;
	$$scalar .= $chunk;
	return length $chunk;
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

	if ( $supercurl->{file} ) {
		close $supercurl->{file};
		$get_obj->print( "DONE " . donemsg( $supercurl ) );
	}

	$get_obj->linedata();

	my $eurl = $curl->getinfo( CURLINFO_EFFECTIVE_URL );
	my $error = $curl->errbuf;
	$curl = undef; # destroy curl before destroying getter

	if ( $err ) {
		#warn "error($err): $error\n";
		$get_obj->print( "ERROR($err): $error" ) if $err ne "aborted";
		if ( $error =~ /Couldn't bind to '(.*)'/ ) {
			my $if = $1;
			RSGet::Dispatch::remove_interface( $if, "Interface $if is dead" );
			$get_obj->{_abort} = "Interface $if is dead";
		} elsif ( $error =~ /transfer closed with (\d+) bytes remaining to read/ ) {
			RSGet::Dispatch::mark_used( $get_obj );
			$get_obj->{_abort} = "PARTIAL " . donemsg( $supercurl );
		} elsif ( $err eq "aborted" ) {

		} else {
			$get_obj->log( "ERROR($err): $error" );
		}
		$get_obj->problem();
		return undef;
	}

	return unless $get_obj->{after_curl};

	my $func = $get_obj->{after_curl};
	if ( $supercurl->{file} ) {
		$get_obj->{dlinfo} = sprintf 'DONE %s %s / %s',
			$supercurl->{fname},
			bignum( $supercurl->{size_got} ),
			bignum( $supercurl->{size_total} );
	} else {
		$get_obj->{body} = $supercurl->{body};
	}

	$get_obj->get_finish( $eurl );
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

my $avg_speed = 0;
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
			my $per = sprintf "%.2f%%", $size_got * 100 / $size_total;
			$size .= " [$per]";
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

		my $speed = "???";
		if ( $time_diff > 0 ) {
			my $s = $size_diff / ( $time_diff * 1024 );
			$speed = sprintf "%.2f", $s;
			$total_speed += $s;
		}

		my $eta = "";
		if ( $size_total > 0 and $time_diff > 0 and $size_diff > 0 ) {
			my $tleft = ($size_total - $size_got) * $time_diff / $size_diff;
			$eta = " " . s2string( $tleft );
			delete $supercurl->{stalled_since}
		}

		$supercurl->{get_obj}->print( "$size; ${speed}KB/s$eta" );
	}
	$avg_speed = ($avg_speed * 9 + $total_speed) / 10;

	my $running = scalar keys %active_curl;
	RSGet::Line::status(
		'running cURL' => $running,
		'total speed' => ( sprintf '%.2fKB/s', $avg_speed )
	);
	return;
}

sub donemsg
{
	my $supercurl = shift;

	my $size_diff = $supercurl->{size_got} - $supercurl->{size_start};
	my $time_diff = time() - $supercurl->{time_start};
	$time_diff = 1 unless $time_diff;
	my $eta = s2string( $time_diff );
	my $speed = sprintf "%.2f", $size_diff / ( $time_diff * 1024 );

	return bignum( $supercurl->{size_got} ) . "; ${speed}KB/s $eta";
}


1;

# vim:ts=4:sw=4