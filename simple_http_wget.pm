# Copyright (C) 2008-2011 Quentin Sculo <squentin@free.fr>
#
# This file is part of Gmusicbrowser.
# Gmusicbrowser is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3, as
# published by the Free Software Foundation

package Simple_http;
use strict;
use warnings;
use LWP::UserAgent;

my $proxy= $::Options{Simplehttp_Proxy}
	? $::Options{Simplehttp_ProxyHost}.':'.($::Options{Simplehttp_ProxyPort}||3128)
	: '';

sub post_with_cb
{
	my $self=bless {};
	my %params=@_;
	$self->{params}=\%params;
	my ($callback,$url,$post,$authtoken)=@params{qw/cb url post authtoken/};

	my $ua = LWP::UserAgent->new();
	#$ua->agent('Mozilla/5.0');
	$ua->default_header('Authorization' => "Token $authtoken") if $authtoken;
	$ua->default_header('Content-Type' => 'application/json') if $authtoken;
	$ua->proxy("https", "connect://$proxy/") if $proxy;
	$ua->timeout(40);

	open my $fh, '<', $post or die "failed to open: $!";
	my $content = do { local $/; <$fh> };
	close $fh;

	my $response = $ua->post($url,
		Content_Type => 'application/json',
    	Content => $content );

	my $result = $response->decoded_content;
	if ($response->is_success) {
		$callback->($result, error=>undef);
	}
	else {
		warn "Error fetching $url : $result\n";
		warn $response->status_line;
		$callback->($response->status_line, error=>$result);
	}
}

sub get_with_cb
{	my $self=bless {};
	my %params=@_;
	$self->{params}=\%params;
	my ($callback,$url,$post,$authtoken)=@params{qw/cb url post authtoken/};

	warn "simple_http_wget : fetching $url\n" if $::debug;

	my $cmd_and_args= 'wget --timeout=40 -S -O -';
	$cmd_and_args.= " -U ".($params{user_agent} || "'Mozilla/5.0'");
	$cmd_and_args.= " --header='Authorization: Token ".$authtoken."'" if $authtoken;
	$cmd_and_args.= " --header='Content-Type: application/json'" if $authtoken;
	$cmd_and_args.= " --referer=$params{referer}" if $params{referer};
	$cmd_and_args.= " --post-file='".$post."'" if $post;
	$cmd_and_args.= " -- '$url'";
	#warn "$cmd_and_args\n";
	
	pipe my($content_fh),my$wfh;
	pipe my($error_fh),my$ewfh;
	my $pid=fork;
	if (!defined $pid) { warn "simple_http_wget : fork failed : $!\n"; Glib::Timeout->add(10,sub {$callback->(); 0}); return $self }
	elsif ($pid==0) #child
	{	close $content_fh; close $error_fh;
		open my($olderr), ">&", \*STDERR;
		open \*STDOUT,'>&='.fileno $wfh;
		open \*STDERR,'>&='.fileno $ewfh;
		exec $cmd_and_args  or print $olderr "launch failed ($cmd_and_args)  : $!\n";
		POSIX::_exit(1);
	}
	close $wfh; close $ewfh;
	$content_fh->blocking(0); #set non-blocking IO
	$error_fh->blocking(0);

	$self->{content_fh}=$content_fh;
	$self->{error_fh}=$error_fh;
	$self->{pid}=$pid;
	$self->{content}=$self->{ebuffer}='';
	$self->{watch}= Glib::IO->add_watch(fileno($content_fh),[qw/hup err in/],\&receiving_cb,$self);
	$self->{ewatch}= Glib::IO->add_watch(fileno($error_fh), [qw/hup err in/],\&receiving_e_cb,$self);

	return $self;
}

#private
sub receiving_e_cb
{	my $self=$_[2];
	return 1 if read $self->{error_fh},$self->{ebuffer},1024,length($self->{ebuffer});
	close $self->{error_fh};
	return $self->{ewatch}=0;
}

#private
sub receiving_cb
{	my $self=$_[2];
	return 1 if read $self->{content_fh},$self->{content},1024,length($self->{content});
	close $self->{content_fh};
	$self->{pid}=$self->{sock}=$self->{watch}=undef;
	my $url=	$self->{params}{url};
	my $callback=	$self->{params}{cb};
	my $type; my $result='';
	$url=$1		while $self->{ebuffer}=~m#^Location: (\w+://[^ ]+)#mg;
	$type=$1	while $self->{ebuffer}=~m#^  Content-Type: (.*)$#mg;	##
	$result=$1	while $self->{ebuffer}=~m#^  (HTTP/1\.\d+.*)$#mg;	##
	#warn $self->{ebuffer};

	my $filename;
	while ($self->{ebuffer}=~m#^  Content-Disposition:\s*\w+\s*;\s*filename(\*)?=(.*)$#mgi)
	{	$filename=$2; my $rfc5987=$1;
		
		$filename=~s#\\(.)#"\x00".ord($1)."\x00"#ge;
		my $enc='iso-8859-1';
		if ($rfc5987 && $filename=~s#^([A-Za-z0-9_-]+)'\w*'##) {$enc=$1; $filename=::decode_url($filename)} #RFC5987
		else
		{	if ($filename=~s/^"(.*)"$/$1/) { $filename=~s#\x00(\d+)\x00#chr($1)#ge; $filename=~s#\\(.)#"\x00".ord($1)."\x00"#ge; }
			elsif ($filename=~m#[^A-Za-z0-9_.\x00-]#) {$filename=''}
		}
		$filename=~s#\x00(\d+)\x00#chr($1)#ge;
		$filename= eval {Encode::decode($enc,$filename)};
	}

	if ($result=~m#^HTTP/1\.\d+ 200 OK#)
	{	my $response=\$self->{content};
		$callback->($$response,type=>$type,url=>$self->{params}{url},filename=>$filename);
	}
	else
	{	warn "Error fetching $url : $result\n";
		$callback->(undef,error=>$result);
	}
	return $self->{watch}=0;
}

1;
