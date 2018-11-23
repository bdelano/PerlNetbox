# Netbox
Script which can be used to interact with [Netbox](https://github.com/digitalocean/netbox).

## Purpose
Specifically designed to convert JSON files created from [CFG2JSON](https://github.com/bdelano/CFG2JSON).

## Usage
See update.pl.example and updatedevice.pm, for inspiration.

## Dependencies
* Curl (could be swapped out for any perl implementation like LWP, but used here to make this as light as possible)
* Perl (tested on 5.14)
  * JSON::PP https://metacpan.org/pod/JSON::PP
  * File::Slurp https://metacpan.org/pod/File::Slurp
  * FindBin https://metacpan.org/pod/FindBin
  * NetAddr::IP https://metacpan.org/pod/NetAddr::IP
  * Time::HiRes https://metacpan.org/pod/Time::HiRes
  * IPC::Cmd https://metacpan.org/pod/IPC::Cmd
  * URI::Encode https://metacpan.org/pod/URI::Encode
