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
	my ($callback,$url)=@params{qw/cb url/};

	my $ua = LWP::UserAgent->new();
	#$ua->agent('Mozilla/5.0');
	$ua->proxy("https", "connect://$proxy/") if $proxy;
	$ua->timeout(40);

	my $response = $ua->get($url);

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

1;
