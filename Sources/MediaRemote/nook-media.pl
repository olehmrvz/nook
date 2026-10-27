# Loads Nook's MediaRemote bridge into this Apple-signed perl, which macOS still lets read "Now Playing".
# Usage: perl nook-media.pl <path to libNookMediaRemote.dylib>
use strict;
use warnings;
use DynaLoader;

my $library = shift or die "usage: nook-media.pl <dylib>\n";
my $handle = DynaLoader::dl_load_file($library, 0) or die DynaLoader::dl_error() . "\n";
my $entry = DynaLoader::dl_find_symbol($handle, "nook_stream") or die DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub("main::stream", $entry);
stream();
