
# Copyright (C) 2014 Quentin Sculo <squentin@free.fr>
#
# This file is part of Gmusicbrowser.
# Gmusicbrowser is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3, as
# published by the Free Software Foundation

#StatusNotifierItem tray icon, used by the "Show tray icon" option when the desktop provides a StatusNotifierWatcher
#requires gir AyatanaAppIndicator3-0.1 (gir1.2-ayatanaappindicator3-0.1 libayatana-appindicator-gtk3)

package GMB::AppIndicator;
use strict;
use warnings;

my ($indicator,$iconpath);

#canonical's libappindicator is gone from most distros, the ayatana fork provides the same api under a different gir namespace
my $found;
for my $ns (qw/AyatanaAppIndicator3 AppIndicator3/)
{	eval { Glib::Object::Introspection->setup( basename => $ns, version => '0.1', package => 'AppIndicator'); 1} and do { $found=$ns; last };
}
die "no typelib found for AyatanaAppIndicator3-0.1 or AppIndicator3-0.1\n" unless $found;

sub Start
{	$indicator ||= AppIndicator::Indicator->new(::PROGRAM_NAME,'gmusicbrowser','application-status');
	# events that requires updating the traymenu :
	::Watch($indicator, $_=> \&QueueUpdate) for qw/Lock Playing Windows/;
	#::Watch($indicator, $_=> \&UpdateIcon) for qw/Playing Icons/; #FIXME needs initialization #deactivated because it can't work for now
	QueueUpdate();
}
sub Stop
{	::UnWatch_all($indicator);
	$indicator->get_menu->destroy;
	$indicator->set_status('passive'); #can't find how to destroy it, so hide it and reuse it if reactivated
}

#true if a StatusNotifierWatcher owns its name on the session bus, ie the desktop can show this icon
my $gio;
sub WatcherPresent
{	my $has= eval
	{	$gio ||= do { Glib::Object::Introspection->setup(basename=>'Gio', version=>'2.0', package=>'GMB::AppIndicator::Gio'); 1 };
		my $bus= GMB::AppIndicator::Gio::bus_get_sync('session', undef);
		my $r= $bus->call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','NameHasOwner',
			Glib::Variant->new('(s)',['org.kde.StatusNotifierWatcher']), Glib::VariantType->new('(b)'), 'none', 1000, undef);
		$r->get('(b)')->[0];
	};
	warn "AppIndicator: can't check for a StatusNotifierWatcher on D-Bus : $@" unless defined $has;
	return $has;
}

sub QueueUpdate
{	::IdleDo('2_AppIndicator',500,\&Update);
}
sub Update
{	delete $::ToDo{'2_AppIndicator'};
	return unless $indicator;
	my $menu= ::BuildMenu(\@::TrayMenu);
	$menu->show_all;
	$indicator->set_status('active');
	$indicator->set_menu($menu);
	my ($menuentry)= grep $_->{id} && $_->{id} eq $::Options{TrayMiddleClick}, $menu->get_children;
	$indicator->set_secondary_activate_target($menuentry) if $menuentry;
}

#doesn't work, needs gmb to switch the standard icon system first #2TO3 could it work now ?
sub UpdateIcon
{	my $state= !defined $::TogPlay ? 'default' : $::TogPlay ? 'play' : 'pause';
	$state='default' unless $::TrayIcon{$state};
	my $path= ::dirname($::TrayIcon{$state});
	my $name= ::barename($::TrayIcon{$state});
	$indicator->set_icon_theme_path($iconpath=$path) if $iconpath && $iconpath ne $path;
	$indicator->set_icon_name_active($name);
}


1;
