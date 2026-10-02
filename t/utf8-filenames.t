use strict;
use warnings;
use utf8;
use Test::More;
use Gtk3;
use Encode qw/_utf8_off/;
use POSIX qw/LC_NUMERIC/;
use Scalar::Util qw/weaken/;
use FindBin;

BEGIN
{	sub _ ($) { $_[0] }
	sub _p ($$) { $_[1] }
	sub __x { my ($s,%h)=@_; $s=~s/{(\w+)}/$h{$1}/g; return $s }
	sub Watch {}
	sub IdleDo {}
	sub superlc { lc $_[0] }
	use constant
	{	TRUE=>1, FALSE=>0, SLASH=>'/', VERSION=>1.109901,
		WINDOW_PADDING=>18, MB=>1000000, DRAG_ARTIST=>4, DRAG_ALBUM=>5,
	};
	$::HomeDir='/tmp/';
	require "$FindBin::Bin/../gmusicbrowser_songs.pm";
}

sub decode_url
{	my $s=$_[0];
	_utf8_off($s);
	$s=~s/%([0-9A-F]{2})/chr hex $1/ieg;
	return $s;
}
sub splitpath
{	my $s=$_[0];
	$s=~s#/([^/]+)$## or die "Expected absolute filename";
	return $s,$1;
}
sub simplify_path { $_[0] }
sub filename_to_utf8displayname { Glib::filename_display_name($_[0]) }

my @names=
(	'2-19 - Coburn - Give me love (Lützenkirchen remix).mp3',
	'[2006-07-10] Renaissance 3D',
	'日本語 - музыка.mp3',
	'100% - literal %C3%BC and %5B.mp3',
	"tabs\tand\nlines\\x41.mp3",
);
for my $name (@names)
{	my $bytes=Encode::encode('UTF-8',$name);
	my $saved=Songs::filename_save($bytes);
	is($saved,$name,'Saving keeps literal Unicode and punctuation');
	is(Songs::filename_load($saved,1),$bytes,'New filenames round-trip to filesystem bytes');
	is(Songs::filename_load(Songs::filename_escape($bytes),0),$bytes,'Legacy filenames remain readable');
	my $line=$saved;
	$line=~s/([\x00-\x1F\\])/sprintf "\\x%02x",ord $1/eg;
	$line=~s/\\x([0-9a-fA-F]{2})/chr hex $1/eg;
	is(Songs::filename_load($line,1),$bytes,'gmbrc line escaping is lossless');
}
my $invalid="non-utf8-\xff.mp3";
my $invalid_saved=Songs::filename_save($invalid);
$invalid_saved=~s/([\x00-\x1F\\])/sprintf "\\x%02x",ord $1/eg;
$invalid_saved=~s/\\x([0-9a-fA-F]{2})/chr hex $1/eg;
is(Songs::filename_load($invalid_saved,1),$invalid,'Non-UTF-8 filenames remain lossless through gmbrc escaping');

@Songs::Fields=qw/path file title artist artist_picture/;
$Songs::Def{artist}{_properties}='artist_picture';
for my $field (@Songs::Fields)
{	my $code=Songs::Code($field,'init');
	Songs::Compile("init_$field",$code) if $code;
}

my $path='/music/[2006-07-10] 日本語';
my $file=$names[0];
my $path_bytes=Encode::encode('UTF-8',$path);
my $file_bytes=Encode::encode('UTF-8',$file);
my $cover="$path/cover ü.jpg";
my $cover_bytes=Encode::encode('UTF-8',$cover);
my ($load,$extras)=Songs::MakeLoadSub({artist=>["artist_picture"]},1,qw/path file title artist/);
ok($load,'New-format loader compiles');
my $id=$load->($path,$file,'Title','Artist');
$extras->{artist}->('Artist',$cover);
is(Songs::GetFullFilename($id),"$path_bytes/$file_bytes",'Generated loader stores canonical filesystem bytes');
my ($save,$fields,$save_extras)=Songs::MakeSaveSub();
ok($save,'UTF-8 saver compiles');
my %values;
@values{@$fields}=$save->($id);
is($values{path},$path,'Generated saver preserves literal brackets and Unicode');
is($values{file},$file,'Generated saver preserves Unicode filename');
is($save_extras->{artist}->()->{Artist}[0],$cover,'Cover filenames also save as UTF-8');
is(Songs::Picture(Songs::Get_gid($id,'artist'),'artist_picture','get'),$cover_bytes,'Cover filenames load as filesystem bytes');

my $warning='';
{	local $SIG{__WARN__}=sub { $warning.=shift };
	ok(!defined $load->($path,$file,'Title','Artist'),'Loading a duplicate does not add another entry');
}
like($warning,qr/already in library/,'Duplicate loading retains its warning');
like($warning,qr/\Q$file\E/,'Duplicate warning displays Unicode correctly');

my ($legacy)=Songs::MakeLoadSub({},0,qw/path file title artist/);
my $legacy_id=$legacy->(Songs::filename_escape($path_bytes),Songs::filename_escape($file_bytes),'Title','Artist');
is(Songs::GetFullFilename($legacy_id),"$path_bytes/$file_bytes",'Generated legacy loader produces the same canonical path');
my @alternate=map Songs::filename_escape($_),$path_bytes,$file_bytes;
s/%([0-9A-F]{2})/'%'.lc($1)/eg for @alternate;
{	local $SIG{__WARN__}=sub { $warning.=shift };
	ok(!defined $legacy->(@alternate,'Title','Artist'),'Legacy duplicates are detected after percent decoding');
}
$Songs::IDFromFile={$path_bytes=>{$file_bytes=>$id}};
is(Songs::FindID("$path/$file"),$id,'Unicode lookups find existing byte-indexed songs');
is(Songs::FindID("$path_bytes/$file_bytes"),$id,'Byte lookups find the same song');
ok(!defined Songs::New("$path/$file"),'Adding an indexed file again does not create a song');

done_testing();
