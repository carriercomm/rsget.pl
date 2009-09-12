package RSGet::HTTPRequest;

use strict;
use warnings;
use IO::Socket;
use RSGet::Line;
use RSGet::Tools;
use RSGet::ListManager;

our %handlers = (
	"main.js" => \&putfile,
	"main.css" => \&putfile,
	"" => \&main_page,
	"update" => \&main_update,
	"log" => \&log,
	add => \&add,
	add_update => \&add_update,
);

my %lastid;

sub xhtml_start
{
	my $js = shift;
	return 
		'<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">' . "\n"
		. '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">'
		. '<head>'
			. '<title>rsget.pl</title>'
			. '<link rel="stylesheet" type="text/css" href="/main.css" media="screen" />'
			. ($js ? qq#<script type="text/javascript" src="/$js"></script># : '')
		. '</head>'
		. '<body>'
		;

}

sub xhtml_end
{
	# no whitespaces here, or .lastChild won't work
	return "</body></html>";
}


sub putfile
{
	my ( $file, $post, $headers ) = @_;

	if ( $file =~ m{^main\.(js|css)$} ) {
		$headers->{Content_Type} = sprintf "text/%s; charset=utf-8", ($1 eq "js" ? "javascript" : "css");

		local $/ = undef;
		open F_IN, '<', $main::data_path . "/data/" . $file;
		$_ = <F_IN>;
		close F_IN;

		return $_;
	}

}

sub main_page
{
	my ( $file, $post, $headers ) = @_;
	my $r = xhtml_start( "main.js" );

	$r .= f_status();
	$r .= f_active();
	$r .= f_log( 6 );
	$r .= f_dllist();
	$r .= f_addform();
	$r .= '<script type="text/javascript">init_main();</script>';
	$r .= xhtml_end();

	return $r;
}

sub main_update
{
	my ( $file, $post, $headers ) = @_;
	my $r = xhtml_start();

	$r .= f_status();

	command( $post->{exec} ) if $post->{exec};

	my $data = {};
	my $nowactive = scalar keys %RSGet::Line::active;
	if ( $nowactive or not exists $post->{active} or $post->{active} != $nowactive ) {
		$r .= f_active();
		$data->{active} = $nowactive;
	}
	if ( not $post->{dead} or $RSGet::Line::dead_change != $post->{dead} ) {
		$r .= f_log( 6 );
		$data->{dead} = $RSGet::Line::dead_change;
	}
	if ( not $post->{dllist} or $post->{dllist} != $RSGet::FileList::listmtime ) {
		$r .= f_dllist();
		$data->{dllist} = $RSGet::FileList::listmtime;
	}
	$r .= '<script type="text/javascript" id="update">/*<![CDATA[/**/';
	$r .= 'var update = ' . scalar_to_js( $data ) . ';';
	$r .= '//]]></script>';
	$r .= xhtml_end();

	return $r;
}


sub log
{
	my ( $file, $post, $headers ) = @_;
	my $r = xhtml_start( );
	$r .= f_log();
	$r .= xhtml_end();

	return $r;
}

sub f_status
{
	my $r = '<fieldset id="f_status"><legend>rsget.pl</legend><ul>';
	foreach my $name ( sort keys %RSGet::Line::status ) {
		my $value = $RSGet::Line::status{ $name };
		next unless $value;
		$r .= qq#<li>$name: $value</li>#;
	}

	$r .= '</ul></fieldset>';
	return $r;
}

sub f_active
{
	$lastid{act} = {};
	my $r = '<fieldset id="f_active"><legend>active</legend><ul>';
	foreach my $key ( sort { $a <=> $b } keys %RSGet::Line::active ) {
		my $line = $RSGet::Line::active{ $key };

		$r .= act_info( $line );
		#$r .= qq#<li><span>$name</span>$value</li>\n#;
	}

	$r .= '</ul></fieldset>';
	return $r;
}

sub act_info
{
	my $act = shift;
	my ( $logo, $line, $o ) = @$act;

	my %wait_to_color = (
		restart => "orange",
		multi => "red",
		problem => "red",
		wait => "blue",
	);
	my $color = $o->{wait} ? $wait_to_color{ $o->{wait} } : "green";

	my $uri = $o->{uri};
	my $uriid = makeid( "act", $uri, $uri );
	my $name = sgml( $o->{name} );
	my $size = bignum( $o->{size} );
	$logo =~ s/ $//;
	$uri = sgml( $uri );

	my $prog = "";
	$prog = qq#<div style="width: $o->{prog}"></div># if $o->{prog};
	$line =~ s/^\Q$o->{name}\E//;
	$line =~ s/^.*?:\s+//;
	$line = sgml( $line );

	return qq#<li id="$uriid" class="active $color">#
		. qq#<span class="logo">$logo</span>#
		. qq#<div class="href"><a href="$uri">$uri</a></div>#
		. qq#<div class="info"><span class="size">$size bytes</span>$name</div>#
		. qq#<div class="progress">$prog<span>$line</span></div>#
		. '</li>';
}


sub f_dllist
{
	my $r = '<fieldset id="f_dllist"><legend>download list</legend>';

	my %cmd_to_color = (
		DONE => "blue",
		GET => "green",
		STOP => "red",
		ADD => "orange",
	);

	$lastid{file} = {};
	$lastid{uri} = {};
	$r .= '<ul class="flist">';
	foreach my $l ( @RSGet::FileList::actual ) {
		unless ( ref $l ) {
			$r .= '<li class="comment">' . href( $l ) . '</li>';
			next;
		}
		my ( $cmd, $g, $uris ) = @$l{ qw(cmd globals uris) };
		my @tools;
		if ( $cmd eq "GET" ) {
			push @tools, "STOP", "!REMOVE";
		} elsif ( $cmd eq "STOP" ) {
			push @tools, "START", "REMOVE";
		} elsif ( $cmd eq "DONE" ) {
			push @tools, "RESTART", "REMOVE";
		}

		my $color = $cmd_to_color{ $cmd };
		my $fileid = makeid( "file", $g->{fname} || (keys %$uris)[0], $uris );

		$r .= qq#<li id="$fileid" class="file $color">#;
		my $size = $g->{fsize} ? bignum( $g->{fsize} ) : "?";
		my $fname = $g->{fname} ? sgml( $g->{fname} ) : "???";
		$r .= qq#<div class="info"><span class="cmd">$cmd</span><span class="size">$size bytes</span>$fname</div>#;

		$r .= '<div class="tools">' . (join " | ", map "<span>$_</span>", @tools) . '</div>';
		$r .= '</li>';

		foreach my $uri ( sort keys %$uris ) {
			$r .= file_info( "uri", $uri, @{$uris->{$uri}} );
		}

	}

	$r .= '</ul>';

	$r .= '</fieldset>';
	return $r;
}

sub file_info
{
	my ( $id_type, $uri, $getter, $o, $tools ) = @_;

	my $bestname = $o->{name} || $o->{iname}
		|| $o->{aname} || $o->{ainame};
	$bestname = sgml( $bestname || "???" );

	my $bestsize = $o->{size} ? bignum( $o->{size} ) : sgml( $o->{asize} || "?" );
	my $uriid = makeid( $id_type, $uri, $uri );

	my $color = "blue";
	$color = "green" if $o->{size} or $o->{asize};
	$color = "red" if $o->{error};
	$color = "orange" if exists $RSGet::Dispatch::downloading{ $uri };

	$uri = sgml( $uri );

	my $errormsg = "";
	my @tools;
	if ( $o->{error} ) {
		push @tools, "CLEAN ERROR", "REMOVE";
		$errormsg = qq#<div class="error">ERROR: # . sgml( $o->{error} ) . qq#</div>#;
	} else {
		push @tools, "DISABLE", ( $id_type eq "uri" ? "!REMOVE" : "REMOVE" );
	}
	@tools = @$tools if $tools;


	return qq#<li id="$uriid" class="uri $color">#
		. qq#<span class="logo">[$getter->{short}]</span>#
		. qq#<div class="href"><a href="$uri">$uri</a></div>#
		. qq#<div class="info"><span class="size">$bestsize</span>$bestname</div>#
		. $errormsg
		. '<div class="tools">' . (join " | ", map "<span>$_</span>", @tools) . '</div>'
		. '</li>';
}

sub f_log
{
	my $max = shift;
	my $start = 0;
	$start = $#RSGet::Line::dead - $max if $max;

	my $r = " " x ( 200 * ( $max || $#RSGet::Line::dead ) ); # allocate some memory
	$r = '<fieldset id="log"><legend>log</legend><ul>';
	
	for ( my $i = $#RSGet::Line::dead; $i >= $start; $i-- ) {
		my $line = $RSGet::Line::dead[ $i ];
		my $class = '';
		$class = ' class="blue"' if $line =~ /PARTIAL/;
		$class = ' class="green"' if $line =~ /DONE/;
		$class = ' class="orange"' if $line =~ /^\[\S+\] WARNING/;
		$class = ' class="red"' if $line =~ /ERROR/;
		$r .= qq#<li$class># . href( $line ) . '</li>';
	}

	$r .= '<li class="comment"><a href="/log">Show more</a></li>' if $max;
	$r .= '</ul></fieldset>';
}

sub sgml
{
	local $_ = shift;
	s/&/&amp;/g;
	s/</&lt;/g;
	s/>/&gt;/g;
	s#\0#<small>(???)</small>#g;
	return $_;
}

sub href
{
	local $_ = sgml( shift );
	s{(^|\s|#)(http://\S*)}{$1<a href="$2">$2</a>}g;
	return $_;
}

sub makeid
{
	my $pre = shift;
	my $id = shift;
	my $data = shift;
	
	$id =~ s/[^a-zA-Z0-9]+/_/g;

	my $idgrp = $lastid{$pre};
	if ( exists $idgrp->{ $id } ) {
		my $i = 1;
		++$i while exists $idgrp->{ "${id}_$i" };
		$id .= "_" . $i;
	}
	$idgrp->{ $id } = $data;

	return "${pre}_$id";
}

sub command
{
	my $exec = shift;
	unless ( $exec =~ s/^(.*?):(.*?)_// ) {
		warn "Invalid command: $exec\n";
		return;
	}
	my $cmd = $1;
	my $grp = $2;

	my $idgrp = $lastid{$grp};
	my $data = $idgrp->{ $exec };
	unless ( $data ) {
		warn "Invalid ID: $cmd, $grp, $exec\n";
		return undef;
	}

	if ( $grp eq "file" ) {
		my @save;
		if ( $cmd eq "STOP" ) {
			@save = qw(cmd STOP);
		} elsif ( $cmd eq "START" or $cmd eq "RESTART" ) {
			@save = qw(cmd GET);
		} elsif ( $cmd =~ /^!?REMOVE$/ ) {
			@save = qw(delete 1);
		} else {
			warn "Invalid command: $cmd, $grp, $exec\n";
			return;
		}
		foreach my $uri ( sort keys %$data ) {
			RSGet::FileList::save( $uri, @save );
		}
	} elsif ( $grp eq "uri" ) {
		my @save;
		if ( $cmd eq "CLEAN ERROR" ) {
			@save = ( options => { error => undef } );
		} elsif ( $cmd eq "DISABLE" ) {
			@save = ( options => { error => "disabled" } );
		} elsif ( $cmd =~ /^!?REMOVE$/ ) {
			@save = qw(delete 1);
		} else {
			warn "Invalid command: $cmd, $grp, $exec\n";
			return;
		}
		RSGet::FileList::save( $data, @save );
	} else {
		warn "Invalid command group: $cmd, $grp, $exec\n";
		return;
	}
	RSGet::FileList::update();
}


sub scalar_to_js
{
	local $_ = shift;

	if ( my $ref = ref $_ ) {
		my $obj;
		if ( $ref eq "HASH" ) {
			my @js;
			foreach my $key ( sort keys %$_ ) {
				my $val = $_->{$key};
				push @js, "'$key': " . scalar_to_js( $val );
			}
			$obj = sprintf "{ %s }", join ", ", @js;
		} elsif ( $ref eq "ARRAY" ) {
			my @js;
			foreach my $val ( @$_ ) {
				push @js, scalar_to_js( $val );
			}
			$obj = sprintf "[ %s ]", join ", ", @js;
		} else {
			warn "Unsupported ref: $ref\n";
		}
		return $obj;
	}

	if ( not defined $_ ) {
		return "null";
	} elsif ( /^(0|-?[1-9]\d*)(\.\d+)?$/ ) {
		return $_;
	} else {
		s/\\/\\\\/g;
		s/"/\\"/g;
		return '"'. $_ .'"';
	}
}

sub f_addform
{
	my $id = shift;
	return '<form action="/add" method="POST"' . ( defined $id ? '>' : ' target="_blank">' )
		. '<fieldset id="add"><legend>Add links to the list</legend>'
		. ( $id ? qq#<input type="hidden" name="id" value="$id" /># : '' )
		. '<textarea cols="100" rows="8" name="links"></textarea>'
		. '<input type="submit" value="OK" />'
		. '</fieldset>'
		. '</form>';
}

sub f_addcomment
{
	my $id = shift;
	return '<form action="/add" method="POST">'
		. '<fieldset id="add"><legend>Add comment (i.e. passwords) to the list</legend>'
		. qq#<input type="hidden" name="id" value="$id" />#
		. '<textarea cols="100" rows="4" name="comment"></textarea>'
		. '<input type="submit" value="OK" />'
		. '</fieldset>'
		. '</form>';
}


sub f_addlist
{
	my $list = shift;

	my $r = '<fieldset id="f_addlist"><legend>Add list</legend>'
		. '<ul class="flist">';
	my $uri_id = "adduri_" . $list->{id};
	$lastid{ $uri_id } = {};

	my $comment = $list->{comment};
	foreach my $l ( @$comment ) {
		$r .= '<li class="comment">' . href( $l ) . '</li>';
	}

	my %cmd_to_color = (
		DONE => "blue",
		GET => "green",
		STOP => "red",
		ADD => "orange",
	);

	my $lines = $list->{lines};
	foreach my $l ( @$lines ) {
		unless ( ref $l ) {
			$r .= '<li class="comment">' . href( $l ) . '</li>';
			next;
		}

		$r .= qq#<li class="file $cmd_to_color{ $l->{cmd} }">#;
		$r .= qq#<div class="info"><span class="cmd">$l->{cmd}</span></div>#;
		$r .= '</li>';

		my $uris = $l->{uris};
		foreach my $uri ( sort keys %$uris ) {
			$r .= file_info( $uri_id, $uri, @{$uris->{$uri}} );
		}
	}

	$r .= '</ul>'
		. '</fieldset>';

	return $r;
}

sub add
{
	my ( $file, $post, $headers ) = @_;
	my $r = xhtml_start( "main.js" );


	my $list;
	$list = RSGet::ListManager::add_list( $post->{links}, $post->{id} )
		if $post->{links};
	$list = RSGet::ListManager::add_list_comment( $post->{comment}, $post->{id} )
		if $post->{comment};

	if ( $list ) {
		$r .= '<fieldset id="f_listask"></fieldset>';
		$r .= f_addlist( $list );
		$r .= f_addcomment( $list->{id} );
		$r .= f_addform( $list->{id} );
		$r .= qq#<script type="text/javascript">init_add( "$list->{id}" );</script>#;
	} else {
		$r .= f_addform( "" );
	}
	$r .= xhtml_end();

	return $r;
}

sub f_askclone
{
	my $ask = shift;
	my $id = shift;
	my $r = '<fieldset id="f_listask"><legend>Select clone</legend>'
		. '<ul class="flist">';
	my ( $uri, $options, $clones ) = @$ask;
	my $getter = RSGet::Dispatch::getter( $uri );
	my $clone_id = "addclone_" . $id;
	$lastid{ $clone_id } = { uri => $uri };
	$r .= file_info( $clone_id, $uri, $getter, $options, [] );
	$r .= '</ul><ul class="flist">';
	foreach my $clone ( @$clones ) {
		foreach my $ucd ( @$clone ) {
			my $uri = $ucd->[0];
			my $options = {
				name => $ucd->[1],
				size => $ucd->[3],
			};
			my $getter = RSGet::Dispatch::getter( $uri );
			$r .= file_info( $clone_id, $uri, $getter, $options, ['SELECT'] );
		}
	}
	{
		$r .= file_info( $clone_id, "NEW SOURCE", $getter,
			{ name => "Add as a separate source" }, ['SELECT'] );
	}
	$r .= '</ul></fieldset>';
	return $r;
}

sub f_askconfirm
{
	my $id = shift;
	my $act = shift;
	my $r = '<fieldset id="f_listask"><legend>Confirm additions</legend>'
		. '<ul class="flist">';
	my $confirm_id = "addlist_" . $id;
	$lastid{ $confirm_id } = {};
	$r .= file_info( $confirm_id, "NEW SOURCES", { short => "OK?" },
		{ name => "Add $act new sources to the list" }, ['CONFIRM'] );
	$r .= '</ul></fieldset>';
	return $r;
}

sub f_msg
{
	my $id = shift;
	my $msg = shift;
	my $class = "";
	$class = ' class="error"' if $msg =~ /^ERROR/;
	return qq#<fieldset id="$id"><h2$class>$msg</h2></fieldset>#;
}

sub add_update
{
	my ( $file, $post, $headers ) = @_;
	my $r = xhtml_start( );

	RSGet::ListManager::add_command( \%lastid, $post->{id}, $post->{exec} ) if $post->{exec};
	my $list = RSGet::ListManager::add_list_update( $post->{id} );
	my $jsdata = 0;
	if ( not $list ) {
		$r .= '<fieldset id="f_listask"></fieldset>';
		$r .= f_msg( "f_addlist", "ERROR: No such add list" );
	} elsif ( not ref $list ) {
		$r .= '<fieldset id="f_listask"></fieldset>';
		$r .= f_msg( "f_addlist", $list );
	} else {
		if ( $post->{select_clone} ) {
			my $ask_clone;
			($list, $ask_clone) = RSGet::ListManager::add_list_clones( $post->{id} );
			if ( $ask_clone ) {
				$r .= f_askclone( $ask_clone, $list->{id} );
			} else {
				$r .= f_askconfirm( $list->{id}, $list->{active} );
			}
		}

		$r .= f_addlist( $list );
		$jsdata = {
			id => $list->{id},
			select_clone => $list->{select_clone} || 0
		};
	}

	$r .= '<script type="text/javascript" id="update">/*<![CDATA[/**/';
	$r .= 'var update = ' . scalar_to_js( $jsdata ) . ';';
	$r .= '//]]></script>';

	$r .= xhtml_end();

	return $r;
}

1;

# vim: ts=4:sw=4