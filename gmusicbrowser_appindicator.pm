
# Copyright (C) 2014 Quentin Sculo <squentin@free.fr>
#
# This file is part of Gmusicbrowser.
# Gmusicbrowser is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3, as
# published by the Free Software Foundation

#StatusNotifierItem tray icon, used by the "Show tray icon" option when the desktop provides a StatusNotifierWatcher
#uses gir AyatanaAppIndicatorGlib-2.0 + Dbusmenu-0.4 + DbusmenuGtk3-0.4 (left click shows/hides the window) if available,
#else AyatanaAppIndicator3-0.1 (gir1.2-ayatanaappindicator3-0.1 libayatana-appindicator-gtk3)

package GMB::AppIndicator;
use strict;
use warnings;

my ($indicator,$iconpath,$menu,$dbusmenu);

Glib::Object::Introspection->setup(basename=>'Gio', version=>'2.0', package=>'GMB::AppIndicator::Gio');

#libayatana-appindicator-glib supports left click, but exports its menu only as org.gtk.Menus, which plasma doesn't read,
#so with it the menu is also exported as com.canonical.dbusmenu using libdbusmenu, like the older libraries do
my $glib= eval
{	Glib::Object::Introspection->setup(basename=>'Dbusmenu', version=>'0.4', package=>'GMB::AppIndicator::Dbusmenu');
	Glib::Object::Introspection->setup(basename=>'DbusmenuGtk3', version=>'0.4', package=>'GMB::AppIndicator::DbusmenuGtk3');
	Glib::Object::Introspection->setup(basename=>'AyatanaAppIndicatorGlib', version=>'2.0', package=>'AppIndicator');
	1;
};

if (!$glib)
{	#canonical's libappindicator is gone from most distros, the ayatana fork provides the same api under a different gir namespace
	my $found;
	for my $ns (qw/AyatanaAppIndicator3 AppIndicator3/)
	{	eval { Glib::Object::Introspection->setup( basename => $ns, version => '0.1', package => 'AppIndicator'); 1} and do { $found=$ns; last };
	}
	die "no typelib found for AyatanaAppIndicatorGlib-2.0, AyatanaAppIndicator3-0.1 or AppIndicator3-0.1\n" unless $found;
}

sub Start
{	if (!$indicator)
	{	$indicator= AppIndicator::Indicator->new(::PROGRAM_NAME,'gmusicbrowser','application-status');
		$indicator->signal_connect(scroll_event => \&Scroll);
		InitGlib() if $glib;
	}
	# events that requires updating the traymenu :
	::Watch($indicator, $_=> \&QueueUpdate) for qw/Lock Playing Windows/;
	#::Watch($indicator, $_=> \&UpdateIcon) for qw/Playing Icons/; #FIXME needs initialization #deactivated because it can't work for now
	::Watch($indicator, CurSong=> \&UpdateTooltip);
	UpdateTooltip();
	QueueUpdate();
}
sub Stop
{	delete $::ToDo{'2_AppIndicator'}; #a queued Update would make it active again
	::UnWatch_all($indicator);
	if ($glib) { $menu->destroy if $menu; $menu=undef }
	elsif (my $m=$indicator->get_menu) { $m->destroy }	#no menu if stopped before the first Update
	$indicator->set_status('passive'); #can't find how to destroy it, so hide it and reuse it if reactivated
}

#touchpads send lots of small deltas, so only change the volume once per mouse wheel notch (120)
my $scrolled=0;
my $inverted= ($ENV{XDG_CURRENT_DESKTOP}//'')=~m/KDE/; #plasma sends Qt's wheel delta (positive=up), the library assumes positive=down
sub Scroll
{	my (undef,$delta,$dir)=@_;
	$dir= (qw/up down left right smooth/)[$dir] if $dir=~m/^\d+$/; #the glib library passes the GdkScrollDirection as a number
	return unless $dir eq 'up' || $dir eq 'down';
	$dir= $dir eq 'up' ? 'down' : 'up' if $inverted;
	$scrolled+= $dir eq 'up' ? $delta : -$delta;
	while ($scrolled>= 120) { ::ChangeVol('up');   $scrolled-=120 }
	while ($scrolled<=-120) { ::ChangeVol('down'); $scrolled+=120 }
}

#true if a StatusNotifierWatcher owns its name on the session bus, ie the desktop can show this icon
sub WatcherPresent
{	my $has= eval
	{	my $bus= GMB::AppIndicator::Gio::bus_get_sync('session', undef);
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
	my $old= $menu;
	$menu= ::BuildMenu(\@::TrayMenu);
	$menu->show_all;
	$indicator->set_status('active');
	if ($glib)
	{	$dbusmenu->set_root( GMB::AppIndicator::DbusmenuGtk3::gtk_parse_menu_structure($menu) ) if $dbusmenu;
		$old->destroy if $old;
	}
	else
	{	$indicator->set_menu($menu);
		my $entry= MiddleClickEntry();
		$indicator->set_secondary_activate_target($entry) if $entry;
	}
}
#plain text, hosts disagree on markup
sub UpdateTooltip
{	my $ID=$::SongID;
	if ($glib)
	{	return unless $indicator->can('set_tooltip');
		my ($title,$desc)= defined $ID ? (::ReplaceFields($ID,'%S'), ::ReplaceFields($ID,"%a\n%l")) : (::PROGRAM_NAME,'');
		$indicator->set_tooltip('',$title,$desc);	#an undef description would clear the title too
	}
	elsif ($indicator->can('set_title')) #used as tooltip by hosts when there is no tooltip api
	{	$indicator->set_title( defined $ID ? ::ReplaceFields($ID,'%S - %a') : ::PROGRAM_NAME );
	}
}
sub MiddleClickEntry
{	my ($entry)= grep $_->{id} && $_->{id} eq $::Options{TrayMiddleClick}, $menu ? $menu->get_children : ();
	return $entry;
}

#### glib library only : left click, middle click and the menu exported as dbusmenu

sub InitGlib
{	my $actions= GMB::AppIndicator::Gio::SimpleActionGroup->new;
	my $middleclick= GMB::AppIndicator::Gio::SimpleAction->new('middleclick',undef);
	$middleclick->signal_connect(activate => sub { my $entry=MiddleClickEntry(); $entry->activate if $entry; });
	$actions->insert($middleclick);
	$indicator->set_actions($actions);
	$indicator->set_menu(GMB::AppIndicator::Gio::Menu->new); #the library requires one, the real menu is the dbusmenu
	$indicator->set_secondary_activate_target('middleclick');
	$indicator->signal_connect(activate => sub { ::ShowHide() });
	$indicator->signal_connect(connection_changed => sub { ExportDbusmenu() if $_[1] });
}

#the dbusmenu has to be on the path of the item's Menu property, the item is found in the watcher's list by our bus name
sub ExportDbusmenu
{	return if defined $dbusmenu;	#exported or pending
	my $bus= GMB::AppIndicator::Gio::bus_get_sync('session', undef);
	my $me= $bus->get_unique_name;
	my $items= eval
	{	my $r= $bus->call_sync('org.kde.StatusNotifierWatcher','/StatusNotifierWatcher','org.freedesktop.DBus.Properties','Get',
			Glib::Variant->new('(ss)',['org.kde.StatusNotifierWatcher','RegisteredStatusNotifierItems']), undef, 'none', 1000, undef);
		$r->get_child_value(0)->get_variant->get('as');
	};
	my ($item)= grep m#^\Q$me\E/#, @{ $items||[] };
	return warn "AppIndicator: tray icon not found in the StatusNotifierWatcher list, its menu won't work\n" unless $item;
	$dbusmenu=0;
	#async, a blocking call to ourselves would deadlock as our main loop has to answer it
	$bus->call($me, substr($item,length $me), 'org.freedesktop.DBus.Properties','Get',
		Glib::Variant->new('(ss)',['org.kde.StatusNotifierItem','Menu']), undef, 'none', 1000, undef, sub
		{	my $path= eval { $bus->call_finish($_[1])->get_child_value(0)->get_variant->get('o') };
			unless ($path) { $dbusmenu=undef; warn "AppIndicator: can't get the menu path of the tray icon : $@"; return }
			$dbusmenu= GMB::AppIndicator::Dbusmenu::Server->new($path);
			$dbusmenu->set_root( GMB::AppIndicator::DbusmenuGtk3::gtk_parse_menu_structure($menu) ) if $menu;
		});
}

####

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
