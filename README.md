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
* JSON file format: (this is produced via CFG2JSON)
```
{
  "model": "S4048-ON",
  "sitename": "us-east-1a",
  "devicerole": "adevicerole",
  "interfaces": {
    "TenGigabitEthernet 1/3": {
      "formfactor": "SFP+10GBASE-LR",
      "description": "test description",
      "ipaddress": [],
      "qualified": "Yes",
      "serial": "aserial1"
    },
    "fortyGigE 1/50": {
      "description": "another interface description",
      "formfactor": "QSFP40GBASE-SR4",
      "serial": "aserial2",
      "qualified": "Yes",
      "ipaddress": []
    },
    "Vlan 4007": {
      "description": "testdescription",
      "formfactor": "virtual",
      "vrf": "aVRF",
      "ipaddress": [
        {
          "bits": "30",
          "version": "4",
          "ip": "10.10.10.74",
          "type": "interface"
        }
      ],
      "vlan": "4007"
    }
  },
  "serial": "devserial",
  "lags": [],
  "version": "9.14(0.0)",
  "mgmtip": "1.1.1.1",
  "hostname": "devhostname",
  "vendor": "force10"
}
```
