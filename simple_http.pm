# Copyright (C) 2008-2011 Quentin Sculo <squentin@free.fr>
#
# This file is part of Gmusicbrowser.
# Gmusicbrowser is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3, as
# published by the Free Software Foundation

package Simple_http;
use strict;
use warnings;
use Mojo::UserAgent;

my $proxy= $::Options{Simplehttp_Proxy}
	? $::Options{Simplehttp_ProxyHost}.':'.($::Options{Simplehttp_ProxyPort}||3128)
	: '';

sub post_with_cb
{
	my $self=bless {};
	my %params=@_;
	$self->{params}=\%params;
	my ($callback,$url,$post,$authtoken)=@params{qw/cb url post authtoken/};

	my $ua = Mojo::UserAgent->new();
	$ua->proxy->https("https://$proxy/") if $proxy;
	$ua->request_timeout(5);
	$ua->max_redirects(3);
	
	my %headers = ('Content-Type' => 'application/json');
	$headers{'Authorization'} = "Token $authtoken" if $authtoken;
	
	open my $fh, '<', $post or die "failed to open: $!";
	my $content = do { local $/; <$fh> };
	close $fh;

	my $tx = $ua->post($url => \%headers => $content);
	process_response($callback, $url, $tx);
}

sub get_with_cb
{
	my $self=bless {};
	my %params=@_;
	$self->{params}=\%params;
	my ($callback,$url)=@params{qw/cb url/};

	my $ua = Mojo::UserAgent->new();
	$ua->proxy->https("https://$proxy/") if $proxy;
	$ua->request_timeout(5);
	$ua->max_redirects(3);

	my $tx = $ua->get($url);
	process_response($callback, $url, $tx);
}

sub process_response
{
	my ($callback,$url,$tx)=@_;
	
	my $res = $tx->res;

	if ($res->is_success) {
		$callback->($res->text, error=>undef);
	}
	else {
		my $err = $tx->error;
		my $status_line = $err->{code} ? "$err->{code} $err->{message}" : $err->{message};
		warn "Error fetching " . $url . " : " . $status_line . "\n";
		$callback->($status_line, error=>$res->text);
	}
}

1;
