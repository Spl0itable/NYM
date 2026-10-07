#!/bin/sh
set -e

project="${1:?usage: patch_flutter_webrtc.sh <flutter project root>}"
config="$project/.dart_tool/package_config.json"

if [ ! -f "$config" ]; then
  echo "error: flutter_webrtc: $config is missing; run flutter pub get first" >&2
  exit 1
fi

root="$(/usr/bin/perl -MJSON::PP -e '
  my ($path, $dir) = @ARGV;
  local $/;
  open(my $fh, "<", $path) or exit 2;
  my $json = decode_json(<$fh>);
  for my $p (@{ $json->{packages} || [] }) {
    next unless $p->{name} eq "flutter_webrtc";
    my $uri = $p->{rootUri};
    $uri =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    if ($uri =~ s{^file://}{}) { print $uri; exit 0; }
    print "$dir/$uri";
    exit 0;
  }
  exit 3;
' "$config" "$project/.dart_tool")" || {
  echo "error: flutter_webrtc is not in $config" >&2
  exit 1
}

root="${root%/}"
patched=0
for rel in ios/flutter_webrtc/Sources/flutter_webrtc ios/Classes common/darwin/Classes; do
  src="$root/$rel/FlutterWebRTCPlugin.m"
  [ -f "$src" ] || continue
  /usr/bin/perl -0pi -e 's/\[\[RTCIceServer alloc\] initWithURLStrings:urls\];/[[RTCIceServer alloc] initWithURLStrings:urls username:nil credential:nil];/g' "$src"
  if grep -Eq 'initWithURLStrings:[A-Za-z_]+[[:space:]]*\]' "$src"; then
    echo "error: flutter_webrtc still calls the one-argument initWithURLStrings: in $src" >&2
    exit 1
  fi
  echo "flutter_webrtc: three-argument RTCIceServer initializer in $src"
  patched=1
done

if [ "$patched" -ne 1 ]; then
  echo "error: flutter_webrtc: no FlutterWebRTCPlugin.m under $root (checked ios/flutter_webrtc/Sources/flutter_webrtc, ios/Classes, common/darwin/Classes); update ios/scripts/patch_flutter_webrtc.sh for the new plugin layout" >&2
  exit 1
fi

if grep -rlq 'buttonPressed:' "$root/ios" "$root/common" 2>/dev/null; then
  echo "error: flutter_webrtc references the private buttonPressed: selector again:" >&2
  grep -rl 'buttonPressed:' "$root/ios" "$root/common" >&2
  exit 1
fi
