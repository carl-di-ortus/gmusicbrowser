# Copyright (C) 2024 Carl di Ortus <reklamukibiras@gmail.com>
#
# This file is part of Gmusicbrowser.
# Gmusicbrowser is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3, as
# published by the Free Software Foundation

=for gmbplugin LISTENBRAINZ
name	listenbrainz
title	listenbrainz.org plugin
desc	Submit played songs to listenbrainz
=cut


package GMB::Plugin::LISTENBRAINZ;
use strict;
use warnings;
use JSON;
use List::Util qw(max);
use constant
{	CLIENTID => 'gmb', VERSION => '0.1',
	OPT => 'PLUGIN_LISTENBRAINZ_', #used to identify the plugin's options
	SAVEFILE => 'listenbrainz.queue', #file used to save unsent data
};
require 'simple_http_wget.pm';

our $ignore_current_song;

my $self=bless {},__PACKAGE__;
my @ToSubmit; my @NowPlaying; my $NowPlayingID;
my $interval=10; my ($timeout,$waiting);
my ($Stop);
my $Log= Gtk3::ListStore->new('Glib::String');

sub Start
{	::Watch($self,PlayingSong=> \&SongChanged);
	::Watch($self,Played => \&Played);
	$self->{on}=1;
	Sleep();
	SongChanged() if $::TogPlay;
	$Stop=undef;
}
sub Stop
{	
	@NowPlaying=undef;
	$waiting->abort if $waiting;
	Glib::Source->remove($timeout) if $timeout;
	$timeout=$waiting=undef;
	::UnWatch($self,$_) for qw/PlayingSong Played/;
	$self->{on}=undef;
	$interval=10;
}

sub prefbox
{	my $vbox= Gtk3::VBox->new(::FALSE, 2);
	my $sg1= Gtk3::SizeGroup->new('horizontal');
	my $sg2= Gtk3::SizeGroup->new('horizontal');
	my $entry2=::NewPrefEntry(OPT.'TOKEN',_"Token :", cb => \&Stop, sizeg1 => $sg1,sizeg2=>$sg2, hide => 1);
	my $label2= Gtk3::Button->new(_"(see https://listenbrainz.org)");
	$label2->set_relief('none');
	$label2->signal_connect(clicked => sub
		{	my $url='https://listenbrainz.org';
			my $user=$::Options{OPT.'USER'};
			$url.="/user/$user/" if defined $user && $user ne '';
			::openurl($url);
		});
	my $ignore= Gtk3::CheckButton->new(_"Don't submit current song");
	$ignore->signal_connect(toggled=>sub { return if $_[0]->{busy}; $ignore_current_song= $_[0]->get_active ? $::SongID : undef; ::HasChanged('Listenbrainz_ignore_current'); });
	::Watch($ignore,Listenbrainz_ignore_current => sub { $_[0]->{busy}=1; $_[0]->set_active(defined $ignore_current_song); delete $_[0]->{busy}; } );
	my $queue= Gtk3::Label->new;
	my $sendnow= Gtk3::Button->new(_"Send now");
	$sendnow->signal_connect(clicked=> \&SendNow);
	my $qbox= ::Hpack($queue,$sendnow);
	$vbox->pack_start($_,::FALSE,::FALSE,0) for $label2,$entry2,$ignore,$qbox;
	$vbox->add( ::LogView($Log) );
	$qbox->{label}=$queue;
	$qbox->{button}=$sendnow;
	$qbox->show_all;
	update_queue_label($qbox);
	$qbox->set_no_show_all(1);
	::Watch($qbox,Listenbrainz_state_change=>\&update_queue_label);
	return $vbox;
}
sub update_queue_label
{	my $qbox=shift;
	my $label= $qbox->{label};
	if (@ToSubmit && (!$waiting && (!$timeout || $interval>10)))
	{	$label->set_text(::__n("song waiting to be sent"));
		$label->get_parent->show;
		$qbox->{button}->set_sensitive(!$waiting);
	}
	else { $label->get_parent->hide }
}

sub SongChanged
{	
	@NowPlaying=undef;
	if (defined $ignore_current_song)
	{	return if defined $::SongID && $::SongID == $ignore_current_song;
		$ignore_current_song=undef; ::HasChanged('Listenbrainz_ignore_current');
	}
	my ($title,$artist,$album)= Songs::Get($::SongID,qw/title artist album/);
	return if $title eq '' || $artist eq '';
	@NowPlaying= ( $artist, $title, $album );
	$NowPlayingID=$::SongID;
	$interval=10;
	SendNow();
}

sub Played
{	my (undef,$ID,undef,$start_time,$seconds,$coverage)=@_;
	return if $ignore_current_song;
	return unless $seconds>10;
	my $length= Songs::Get($ID,'length');
	if ($length>=30 && ($seconds >= 240 || $coverage >= .5) )
	{	my ($title,$artist,$album)= Songs::Get($ID,qw/title artist album/);
		return if $title eq '' || $artist eq '';
		@ToSubmit= ( $artist, $title, $album );
		$interval=10;
		Sleep();
		::QHasChanged('Listenbrainz_state_change');
	}
}

sub Submit
{
	my $i=0;
	my $url= 'https://api.listenbrainz.org/1/submit-listens';
	my $listen_type;
	my $listened_at;
	my @payload;
	if (@ToSubmit)
	{	@payload= @ToSubmit;
		$listen_type= "single";
		$listened_at= time();
	}
	elsif (@NowPlaying)
	{	if (!defined $::PlayingID || $::PlayingID!=$NowPlayingID) { @NowPlaying=undef; return }
		@payload= @NowPlaying;
		$listen_type= "playing_now";
		$listened_at= undef;
	}
	else { return; }
	my $post= {
		listen_type => $listen_type,
		payload => [
			{
				#listened_at => $listened_at,
				track_metadata => {
					artist_name => $payload[0],
					track_name => $payload[1]
					#release_name => $payload[2]
				}
			}
		]
	};
	$post->{payload}[0]->{listened_at} = $listened_at if $listened_at;
	$post->{payload}[0]->{track_metadata}->{release_name} = $payload[2] if $payload[2];
	my $response_cb=sub
	{	
		my ($response,@lines)=@_;
		my $error;
		if	(!defined $response) {$error=_"connection failed";}
		elsif	($response eq '{"status":"ok"}')
		{	unlink $::HomeDir.SAVEFILE;
			if (@ToSubmit) { 
				Log( _("Submit OK ") .
					::__x( _"{song} by {artist}", song=> $payload[1], artist => $payload[0]) );
				undef @ToSubmit;
				undef $waiting;
				$interval=10;
				return
			};
			if (@NowPlaying) {
				Log( _("NowPlaying OK ") .
					::__x( _"{song} by {artist}", song=> $payload[1], artist => $payload[0]) );
				$interval=60;
				undef $waiting;
				return
			};
		}
		elsif	($response eq 'BADSESSION')
		{	$error=_"Bad session";
		}
		elsif	($response=~m/^FAILED (.*)$/)
		{	$error=$1;
		}
		else	{$error=_"unknown error";}

		if (defined $error)
		{	Log(_("Submit failed : ").$error);
			Log(_("Response : ").$response) if $response;
			$interval*=2;
			$interval=max($interval, 300);
		}
	};

	my $authtoken=$::Options{OPT.'TOKEN'};
	Save($post);
	Send($response_cb,$url,$::HomeDir.SAVEFILE,$authtoken);
}

sub SendNow
{	$interval=10;
	$Stop=undef;
	Glib::Source->remove($timeout) if $timeout;
	Awake();
}

sub Sleep
{	return unless $self->{on};
	::QHasChanged('Listenbrainz_state_change');
	return if $Stop || $waiting || $timeout;
	$timeout=Glib::Timeout->add(1000*$interval,\&Awake) if @ToSubmit || @NowPlaying;
}

sub Awake
{	Glib::Source->remove($timeout) if $timeout;
	$timeout=undef;
	return 0 if !$self->{on} || $waiting;
	Submit();
	Sleep();
	return 0;
}

sub Send
{	my ($response_cb,$url,$post,$authtoken)=@_;
	my $cb=sub
	{	my @response=(defined $_[0])? split "\012",$_[0] : ();
		$waiting=undef;
		&$response_cb(@response);
		Sleep();
	};

	$waiting=Simple_http::get_with_cb(cb => $cb,url => $url,post => $post,authtoken => $authtoken);
	::QHasChanged('Listenbrainz_state_change');
}

sub Log
{	my $text=$_[0];
	$Log->set( $Log->prepend,0, localtime().'  '.$text );
	warn "$text\n" if $::debug;
	if (my $iter=$Log->iter_nth_child(undef,50)) { $Log->remove($iter); }
}

sub Save
{	my $savebody=$_[0];
	unless ($savebody)
	{ unlink $::HomeDir.SAVEFILE; return }
	my $fh;
	unless (open $fh,'>:utf8',$::HomeDir.SAVEFILE)
	 { warn "Error creating '$::HomeDir".SAVEFILE."' : $!\nUnsent listenbrainz.org data will be lost.\n"; return; }
	my $json=(to_json $savebody);
	print $fh $json;
	close $fh;
}

1;
