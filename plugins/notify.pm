# Copyright (C) 2009-2010 Quentin Sculo <squentin@free.fr>
#
# This file is part of Gmusicbrowser.
# Gmusicbrowser is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3, as
# published by the Free Software Foundation

=for gmbplugin NOTIFY
name	Notify
title	Notify plugin
desc	Notify you of the playing song with the system's notification popups
req	gir(Notify-0.7, gir1.2-notify-0.7 libnotify-0.7)
=cut

package GMB::Plugin::NOTIFY;
use strict;
use warnings;
use Time::HiRes ();
use constant
{	OPT	=> 'PLUGIN_NOTIFY_',
};

::SetDefaultOptions(OPT, title => "%S", text => _"<i>by</i> %a\\n<i>from</i> %l", picsize => 50, timeout=>5);

my $notify;
my $last_shown=0;
my $paused_ID;	#to recognize a resume from pause
my ($Daemon_name,$can_actions,$can_body);

Glib::Object::Introspection->setup( basename => 'Notify', version => '0.7', package => 'Notify',
		flatten_array_ref_return_for => [qw/Notify::get_server_caps/]);

sub Init
{	Notify::init(::PROGRAM_NAME);
	Notify::set_app_icon('gmusicbrowser') if defined &Notify::set_app_icon;	#libnotify >= 0.8.4
}

sub Start
{	$notify= Notify::Notification->new('empty');
	$notify->set_hint('desktop-entry', Glib::Variant->new_string('gmusicbrowser'));
	$notify->set_urgency('low');
	$notify->set_hint('transient', Glib::Variant->new_boolean(1));	#don't keep song notifications in the daemon's history
	#$notify->set_category('music'); #is there a standard category for that ?
	my ($ok, $name, $vendor, $version, $spec_version)= Notify::get_server_info();
	$Daemon_name= $ok ? "$name $version ($vendor)" : _"None";
	my @caps = Notify::get_server_caps();
	$can_body=	grep $_ eq 'body',	@caps;
	$can_actions=	grep $_ eq 'actions',	@caps;
	set_actions();
	::Watch($notify,'PlayingSong',\&SongStarted);
	::Watch($notify,'Playing',\&PlayingChanged);
	$::Command{PopupNotify}=[\&Changed,_"Popup notify window"];
}
sub Stop
{	::UnWatch_all($notify);
	eval { $notify->close } if $notify->get('id');	#remove the popup if still shown, dies if it's gone already
	$notify=undef;
	delete $::Command{PopupNotify};
}

sub prefbox
{	my $vbox=Gtk3::VBox->new(::FALSE, 2);
	my $sg1= Gtk3::SizeGroup->new('horizontal');
	my $sg2= Gtk3::SizeGroup->new('horizontal');
	my $replacetext=::MakeReplaceText('talydngLfS');
	my $summary=::NewPrefEntry(OPT.'title',_"Summary :", sizeg1=> $sg1, sizeg2=>$sg2, tip => $replacetext);
	my $body=   ::NewPrefEntry(OPT.'text', _"Body :",    sizeg1=> $sg1, sizeg2=>$sg2, width=>40, tip => $replacetext."\n\n"._("You can use some markup, eg :\n<b>bold</b> <i>italic</i> <u>underline</u>\nNote that the markup may be ignored by the notification daemon"),);
	my $size=   ::NewPrefSpinButton(OPT.'picsize', 0,1000, step=>10, page=>40, text=>_"Picture size : %d", sizeg1=>$sg1, tip=> _"Note that some notification daemons resize the displayed picture");
	my $timeout=::NewPrefSpinButton(OPT.'timeout', 0,9999, step=>2,  page=>5,  text=>_"Timeout : %d seconds", sizeg1=>$sg1, digits=>1);
	my $actions=::NewPrefCheckButton(OPT.'actions',_"Display previous, play/pause and next actions", cb=>\&set_actions);
	$actions->set_sensitive($can_actions);
	$actions->set_tooltip_text(_("Actions are not supported by current notification daemon").' : '.$Daemon_name) unless $can_actions;
	$body->set_sensitive($can_body);
	$body->set_tooltip_text(_("Body text is not supported by current notification daemon").' : '.$Daemon_name) unless $can_body;
	my $whenhidden=::NewPrefCheckButton(OPT.'onlywhenhidden',_"Don't notify if the main window is visible");
	my $onresume=::NewPrefCheckButton(OPT.'onresume',_"Notify when resuming from pause");
	$vbox->pack_start($_,::FALSE,::FALSE,2) for $summary,$body,$size,$timeout,$actions,$whenhidden,$onresume;
	return $vbox;
}

sub PlayingChanged
{	if (!defined $::TogPlay)	{ $paused_ID=undef }	#stopped
	elsif (!$::TogPlay)		{ $paused_ID=$::SongID }	#paused
}

sub SongStarted
{	my $resumed= defined $paused_ID && $paused_ID==$::SongID;
	$paused_ID=undef;
	Changed() unless $resumed && !$::Options{OPT.'onresume'};
}

sub Changed
{	return if $::Options{OPT.'onlywhenhidden'} && ::IsWindowVisible($::MainWindow);
	my $ID=$::SongID;
	my $title=$::Options{OPT.'title'};
	my $text= $::Options{OPT.'text'};
	my $size= $::Options{OPT.'picsize'};
	my $timeout=$::Options{OPT.'timeout'}*1000;
	return unless $title || $text || $size;
	$title= ::ReplaceFields($ID,$title) || " ";	#libnotify do not like null summaries
	$notify->update($title, ::ReplaceFieldsAndEsc($ID,$text) );
	my $pixbuf;
	if ($size)
	{	my $album_gid= Songs::Get_gid($ID,'album');
		$pixbuf=AAPicture::pixbuf('album', $album_gid, $size, 1);
	}
	if ($pixbuf)	{ $notify->set_image_from_pixbuf($pixbuf) }
	else		{ $notify->set_hint('image-data',undef) }	#remove previous picture, set_image_from_pixbuf doesn't accept undef
	$notify->set_timeout($timeout);
	#replacing a timed out notification can update it silently without a popup (plasma keeps it in its history)
	$notify->set_property(id=>0) unless $timeout==0 || Time::HiRes::time()-$last_shown < $timeout/1000;
	set_actions();	#play/pause label depends on the current state
	if (eval { $notify->show; 1 })	{ $last_shown= Time::HiRes::time(); }
	else				{ warn "Notify plugin : $@"; }
}

sub ShowMainWindow
{	my $notification=shift;
	::ShowHide(1);
	#on wayland the window only gets the focus with the activation token of the click, set_startup_id passes it on
	my $token= $notification->can('get_activation_token') && $notification->get_activation_token;
	$::MainWindow->set_startup_id($token) if $token;
}

sub set_actions
{	return unless $can_actions;
	$notify->clear_actions;
	$notify->add_action('default',_"Show",\&ShowMainWindow);	#clicking the notification
	if ($::Options{OPT.'actions'})
	{	$notify->add_action('media-skip-backward',_"Previous",\&::PrevSong);
		$notify->add_action($::TogPlay ? ('media-playback-pause',_"Pause") : ('media-playback-start',_"Play"), \&::PlayPause);
		$notify->add_action('media-skip-forward',_"Next",\&::NextSong);
	}
}

1
